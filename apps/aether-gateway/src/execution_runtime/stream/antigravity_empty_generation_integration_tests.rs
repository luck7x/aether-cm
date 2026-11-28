use super::*;

fn input_only_generation() -> String {
    format!(
        "data: {}\n\n",
        json!({"response": {
            "candidates": [{"content": {"role": "model", "parts": []}}],
            "usageMetadata": {"promptTokenCount": 123, "totalTokenCount": 123}
        }})
    )
}

async fn generation_fixture(
    model: &str,
    envelope: &str,
    stop_502: bool,
) -> (AppState, ExecutionPlan, Value, String) {
    let request_id = format!("empty-generation-{}", uuid::Uuid::new_v4());
    let mut plan = antigravity_gemini_stream_plan(&request_id);
    plan.client_api_format = "gemini:generate_content".into();
    // The requested/display names need not identify the actual upstream model.
    plan.model_name = Some("client-model-alias".into());
    plan.body = RequestBody::from_json(json!({
        "model": model,
        "request": {"contents": [{"role": "user", "parts": [{"text": "test"}]}]}
    }));
    let catalog = Arc::new(provider_catalog_for_plan(
        &plan,
        Some(json!({
            "pool_advanced": {
                "overload_cooldown_seconds": 60,
                "rate_limit_cooldown_seconds": 60
            },
            "failover_rules": {"stop_status_codes": if stop_502 { vec![502] } else { vec![] }}
        })),
    ));
    let state = AppState::new()
        .expect("synthetic app state should build")
        .with_data_state_for_tests(
            crate::data::GatewayDataState::with_provider_catalog_repository_for_tests(catalog)
                .with_encryption_key_for_tests(DEVELOPMENT_ENCRYPTION_KEY),
        );
    let lease_key = format!("synthetic-generation-lease-{request_id}");
    let lease = state
        .runtime_state
        .lock_try_acquire(&lease_key, "synthetic-test", Duration::from_secs(60))
        .await
        .expect("memory lease acquisition should succeed")
        .expect("synthetic lease should be available");
    let mut context = json!({
        "request_id": request_id,
        "candidate_id": plan.candidate_id,
        "candidate_index": 0,
        "retry_index": 0,
        "provider_id": plan.provider_id,
        "endpoint_id": plan.endpoint_id,
        "key_id": plan.key_id,
        "provider_api_format": plan.provider_api_format,
        "client_api_format": plan.client_api_format,
        "mapped_model": model,
        "has_envelope": true,
        "envelope_name": envelope,
        "needs_conversion": false
    });
    crate::orchestration::insert_pool_key_lease_report_context_fields(
        context
            .as_object_mut()
            .expect("context should be an object"),
        Some(&lease),
    );
    (state, plan, context, lease_key)
}

async fn execute_generation_frames(
    state: &AppState,
    plan: &ExecutionPlan,
    context: Value,
    chunks: Vec<String>,
    explicit_eof: bool,
    upstream_status: u16,
    allow_retry: bool,
) -> AiAttemptExecutionOutcome<axum::http::Response<Body>> {
    let frames = stream! {
        yield Ok::<Bytes, std::io::Error>(ndjson_frame(StreamFrame {
            frame_type: StreamFrameType::Headers,
            payload: StreamFramePayload::Headers {
                status_code: upstream_status,
                headers: BTreeMap::from([("content-type".into(), "text/event-stream".into())]),
                response_observation: None,
            },
        }));
        for chunk in chunks {
            yield Ok(ndjson_frame(StreamFrame {
                frame_type: StreamFrameType::Data,
                payload: StreamFramePayload::Data { text: Some(chunk), chunk_b64: None },
            }));
        }
        if explicit_eof {
            yield Ok(ndjson_frame(StreamFrame::eof()));
        }
    }
    .boxed();
    let mut scope = AiAttemptRetryScope::Provider;
    let mut fallback_response = None;
    let response = execute_stream_from_frame_stream_with_retry_scope(
        state,
        plan.clone(),
        "trace-synthetic-empty-generation",
        &test_decision(),
        "gemini_chat_stream",
        Some("gemini_chat_stream_success".into()),
        Some(context),
        crate::clock::current_unix_ms(),
        Instant::now(),
        RequestStageTrace::from_env(),
        true,
        frames,
        false,
        None,
        if allow_retry { Some(&mut scope) } else { None },
        Some(&mut fallback_response),
        None,
    )
    .await
    .expect("synthetic frame execution should succeed");
    match response {
        Some(response) => AiAttemptExecutionOutcome::Responded(response),
        None => AiAttemptExecutionOutcome::Retry {
            scope,
            fallback_response,
        },
    }
}

async fn stored_generation_key(state: &AppState, plan: &ExecutionPlan) -> StoredProviderCatalogKey {
    state
        .read_provider_catalog_keys_by_ids(std::slice::from_ref(&plan.key_id))
        .await
        .expect("catalog key should load")
        .into_iter()
        .next()
        .expect("synthetic key should exist")
}

async fn generation_cooldown(state: &AppState, plan: &ExecutionPlan) -> Option<String> {
    state
        .runtime_state
        .kv_get(&format!("ap:{}:cooldown:{}", plan.provider_id, plan.key_id))
        .await
        .expect("memory cooldown lookup should succeed")
}

async fn assert_generation_lease_released(state: &AppState, lease_key: &str) {
    let lease = state
        .runtime_state
        .lock_try_acquire(lease_key, "next-request", Duration::from_secs(60))
        .await
        .expect("replacement memory lease acquisition should succeed")
        .expect("failed attempt must release its lease before the next request");
    state.runtime_state.lock_release(&lease).await.unwrap();
}

async fn assert_empty_generation_response(response: axum::http::Response<Body>) {
    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    assert_eq!(response.headers()[header::CONTENT_TYPE], "application/json");
    let body = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    let body: Value = serde_json::from_slice(&body).expect("error should be native Gemini JSON");
    assert_eq!(body["error"]["code"], 502);
    assert_eq!(body["error"]["status"], "INTERNAL");
    assert_eq!(body["error"]["type"], "antigravity_empty_generation");
    assert!(!body["error"]["message"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn hydrogen_empty_generation_both_eof_paths_retry_without_account_penalties() {
    for model in ["gemini-4-hydrogen", "gemini-4-hydrogen-sonar"] {
        for explicit_eof in [false, true] {
            let (state, plan, context, lease_key) =
                generation_fixture(model, "antigravity:v1internal", false).await;
            let before = stored_generation_key(&state, &plan).await;
            // A transport split must not change classification of the complete SSE record.
            let data = input_only_generation();
            let midpoint = data.len() / 2;
            let outcome = execute_generation_frames(
                &state,
                &plan,
                context,
                vec![data[..midpoint].into(), data[midpoint..].into()],
                explicit_eof,
                200,
                true,
            )
            .await;
            let AiAttemptExecutionOutcome::Retry {
                scope,
                fallback_response: Some(response),
            } = outcome
            else {
                panic!("recognized empty generation should retry with a diagnostic fallback");
            };
            assert_eq!(scope, AiAttemptRetryScope::Credential);
            assert_empty_generation_response(response).await;
            let after = stored_generation_key(&state, &plan).await;
            assert_eq!(after.health_by_format, before.health_by_format);
            assert_eq!(
                after.circuit_breaker_by_format,
                before.circuit_breaker_by_format
            );
            assert_eq!(after.rpm_429_count, before.rpm_429_count);
            assert_eq!(after.last_429_at_unix_secs, before.last_429_at_unix_secs);
            assert_eq!(generation_cooldown(&state, &plan).await, None);
            assert_generation_lease_released(&state, &lease_key).await;
        }
    }
}

#[tokio::test]
async fn hydrogen_empty_generation_respects_stop_policy_and_missing_retry_outlet() {
    for (stop_502, allow_retry) in [(true, true), (false, false)] {
        let (state, plan, context, lease_key) =
            generation_fixture("gemini-4-hydrogen", "antigravity:v1internal", stop_502).await;
        let before = stored_generation_key(&state, &plan).await;
        let outcome = execute_generation_frames(
            &state,
            &plan,
            context,
            vec![input_only_generation()],
            true,
            200,
            allow_retry,
        )
        .await;
        let AiAttemptExecutionOutcome::Responded(response) = outcome else {
            panic!("stopped execution must respond directly instead of scheduling a retry");
        };
        assert_empty_generation_response(response).await;
        assert_eq!(
            stored_generation_key(&state, &plan).await.health_by_format,
            before.health_by_format
        );
        assert_eq!(generation_cooldown(&state, &plan).await, None);
        assert_generation_lease_released(&state, &lease_key).await;
    }
}

#[tokio::test]
async fn flash_other_envelope_and_bare_disconnect_keep_existing_failure_effects() {
    for (model, envelope, data) in [
        (
            "gemini-3.7-flash-tiered",
            "antigravity:v1internal",
            input_only_generation(),
        ),
        (
            "gemini-4-hydrogen",
            "gemini_cli:v1internal",
            input_only_generation(),
        ),
        ("gemini-4-hydrogen", "antigravity:v1internal", String::new()),
    ] {
        let (state, plan, context, lease_key) = generation_fixture(model, envelope, false).await;
        let outcome =
            execute_generation_frames(&state, &plan, context, vec![data], true, 200, true).await;
        let AiAttemptExecutionOutcome::Retry {
            scope,
            fallback_response,
        } = outcome
        else {
            panic!("ordinary presemantic EOF should preserve the existing retry path");
        };
        assert_eq!(scope, AiAttemptRetryScope::Candidate);
        assert!(fallback_response.is_none());
        assert_eq!(
            generation_cooldown(&state, &plan).await.as_deref(),
            Some("server_error_500")
        );
        let key = stored_generation_key(&state, &plan).await;
        assert_eq!(
            key.health_by_format.as_ref().unwrap()["gemini:generate_content"]
                ["consecutive_failures"],
            1
        );
        assert_generation_lease_released(&state, &lease_key).await;
    }
}

#[tokio::test]
async fn hydrogen_real_http_429_keeps_rate_limit_feedback() {
    for (body, expected_cooldown) in [
        (
            json!({"error": {"code": 429, "status": "RESOURCE_EXHAUSTED", "message": "slow down"}}),
            "quota_exhausted_429",
        ),
        (
            json!({"error": {"code": 429, "message": "Too many requests"}}),
            "rate_limited_429",
        ),
    ] {
        let (state, plan, context, lease_key) =
            generation_fixture("gemini-4-hydrogen", "antigravity:v1internal", false).await;
        let outcome = execute_generation_frames(
            &state,
            &plan,
            context,
            vec![body.to_string()],
            true,
            429,
            true,
        )
        .await;
        assert!(matches!(
            outcome,
            AiAttemptExecutionOutcome::Retry {
                scope: AiAttemptRetryScope::Candidate,
                ..
            }
        ));
        assert_eq!(
            generation_cooldown(&state, &plan).await.as_deref(),
            Some(expected_cooldown)
        );
        let key = stored_generation_key(&state, &plan).await;
        let health = &key.health_by_format.as_ref().unwrap()["gemini:generate_content"];
        assert_eq!(health["consecutive_failures"], 1);
        assert_eq!(health["health_score"], json!(0.7));
        assert_generation_lease_released(&state, &lease_key).await;
    }
}

#[tokio::test]
async fn hydrogen_successful_generation_is_forwarded_without_empty_generation_error() {
    let (state, plan, context, _) =
        generation_fixture("gemini-4-hydrogen", "antigravity:v1internal", false).await;
    let chunk = format!(
        "data: {}\n\n",
        json!({"response": {
            "candidates": [{"content": {"role": "model", "parts": [{"text": "ok"}]}, "finishReason": "STOP"}],
            "usageMetadata": {"promptTokenCount": 123, "candidatesTokenCount": 1, "totalTokenCount": 124}
        }})
    );
    let outcome =
        execute_generation_frames(&state, &plan, context, vec![chunk], true, 200, true).await;
    let AiAttemptExecutionOutcome::Responded(response) = outcome else {
        panic!("normal generated content should be delivered");
    };
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    let text = std::str::from_utf8(&bytes).unwrap();
    assert!(text.contains("ok"));
    assert!(!text.contains("antigravity_empty_generation"));
    assert_eq!(generation_cooldown(&state, &plan).await, None);
}
