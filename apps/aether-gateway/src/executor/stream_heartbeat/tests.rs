use std::future::Future;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::body::{to_bytes, Body, Bytes};
use axum::http::{Response, StatusCode};
use futures_util::StreamExt;
use serde_json::{json, Value};
use tokio::sync::oneshot;

use super::{execute_with_timing, should_wrap, COMMENT};
use crate::control::GatewayControlDecision;
use crate::executor::LocalExecutionRequestOutcome;
use crate::{AppState, GatewayError};

const GRACE: Duration = Duration::from_millis(5);
const INTERVAL: Duration = Duration::from_millis(5);

fn decision() -> GatewayControlDecision {
    GatewayControlDecision::synthetic(
        "/v1beta/models/gemini-test:streamGenerateContent?alt=sse",
        Some("ai_public".to_string()),
        Some("gemini".to_string()),
        Some("generate_content".to_string()),
        Some("gemini:generate_content".to_string()),
    )
    .with_execution_runtime_candidate(true)
}

fn parts() -> http::request::Parts {
    http::Request::builder()
        .uri("/v1beta/models/gemini-test:streamGenerateContent?alt=sse")
        .body(())
        .unwrap()
        .into_parts()
        .0
}

fn sse(body: Body) -> LocalExecutionRequestOutcome {
    LocalExecutionRequestOutcome::responded(
        Response::builder()
            .header(http::header::CONTENT_TYPE, "text/event-stream")
            .body(body)
            .unwrap(),
    )
}

async fn shell<F>(execute: F) -> Response<Body>
where
    F: Future<Output = Result<LocalExecutionRequestOutcome, GatewayError>> + Send + 'static,
{
    let result = execute_with_timing(
        AppState::new().unwrap(),
        parts(),
        "heartbeat-test".to_string(),
        decision(),
        execute,
        GRACE,
        INTERVAL,
    )
    .await
    .unwrap();
    let LocalExecutionRequestOutcome::Responded(response) = result else {
        panic!("response expected")
    };
    response
}

#[test]
fn only_explicit_gemini_sse_with_enabled_policy_is_wrapped() {
    let policy = aether_routing_core::RoutingExecutionPolicy {
        enable_cf_heartbeat: true,
        ..Default::default()
    };
    for kind in ["gemini_chat_stream", "gemini_cli_stream"] {
        assert!(should_wrap(&parts(), kind, Some(policy.clone())));
        assert!(!should_wrap(&parts(), kind, Some(Default::default())));
        assert!(!should_wrap(&parts(), kind, None));
    }
    for kind in [
        "openai_chat_stream",
        "claude_chat_stream",
        "gemini_files_download",
        "gemini_chat_sync",
    ] {
        assert!(!should_wrap(&parts(), kind, Some(policy.clone())));
    }
    let (mut no_sse, _) = http::Request::builder()
        .uri("/v1beta/models/test:streamGenerateContent")
        .body(())
        .unwrap()
        .into_parts();
    assert!(!should_wrap(
        &no_sse,
        "gemini_chat_stream",
        Some(policy.clone())
    ));
    no_sse.headers.insert(
        http::header::ACCEPT,
        http::HeaderValue::from_static("text/event-stream"),
    );
    assert!(should_wrap(&no_sse, "gemini_chat_stream", Some(policy)));
}

#[tokio::test]
async fn fast_error_retains_original_http_status_and_body() {
    let response = shell(async {
        Ok(LocalExecutionRequestOutcome::responded(
            Response::builder()
                .status(StatusCode::TOO_MANY_REQUESTS)
                .header("x-test", "preserved")
                .body(Body::from("original upstream error"))
                .unwrap(),
        ))
    })
    .await;
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(response.headers()["x-test"], "preserved");
    assert_eq!(
        to_bytes(response.into_body(), 1024).await.unwrap(),
        "original upstream error"
    );
}

#[tokio::test]
async fn keepalives_cover_multiple_attempts_before_success_without_json_injection() {
    let (release_tx, release_rx) = oneshot::channel::<()>();
    let attempts = Arc::new(AtomicUsize::new(0));
    let observed = attempts.clone();
    let response = shell(async move {
        for _ in 0..2 {
            observed.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(15)).await;
        }
        let _ = release_rx.await;
        observed.fetch_add(1, Ordering::SeqCst);
        Ok(sse(Body::from(
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"OK\"}]}}]}\n\n",
        )))
    })
    .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["x-accel-buffering"], "no");
    let mut body = response.into_body().into_data_stream();
    for _ in 0..3 {
        assert_eq!(body.next().await.unwrap().unwrap().as_ref(), COMMENT);
    }
    release_tx.send(()).unwrap();
    let mut data = Vec::new();
    while let Some(chunk) = body.next().await {
        let chunk = chunk.unwrap();
        if chunk.as_ref() != COMMENT {
            data.extend_from_slice(&chunk);
        }
    }
    assert_eq!(attempts.load(Ordering::SeqCst), 3);
    assert_eq!(
        String::from_utf8(data).unwrap(),
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"OK\"}]}}]}\n\n"
    );
}

#[tokio::test]
async fn late_failure_is_native_gemini_error_and_does_not_expose_html() {
    let (send, recv) = oneshot::channel();
    let response = shell(async move {
        let _ = recv.await;
        Ok(LocalExecutionRequestOutcome::responded(
            Response::builder()
                .status(StatusCode::FORBIDDEN)
                .body(Body::from("<html>private upstream error details</html>"))
                .unwrap(),
        ))
    })
    .await;
    let mut body = response.into_body().into_data_stream();
    assert_eq!(body.next().await.unwrap().unwrap().as_ref(), COMMENT);
    send.send(()).unwrap();
    let data = body.next().await.unwrap().unwrap();
    let text = std::str::from_utf8(&data).unwrap();
    let error: Value = serde_json::from_str(text.trim().strip_prefix("data: ").unwrap()).unwrap();
    assert_eq!(error["error"]["code"], 403);
    assert_eq!(error["error"]["status"], "PERMISSION_DENIED");
    assert!(!text.contains("private"));
    assert!(!text.contains("[DONE]"));
    assert!(body.next().await.is_none());
}

#[tokio::test]
async fn late_no_route_and_internal_errors_finish_with_native_events() {
    for code in [503, 502] {
        let (send, recv) = oneshot::channel::<()>();
        let response = shell(async move {
            let _ = recv.await;
            if code == 503 {
                Ok(LocalExecutionRequestOutcome::NoPath)
            } else {
                Err(GatewayError::Internal("private internal details".into()))
            }
        })
        .await;
        let mut body = response.into_body().into_data_stream();
        assert_eq!(body.next().await.unwrap().unwrap().as_ref(), COMMENT);
        send.send(()).unwrap();
        let event = body.next().await.unwrap().unwrap();
        let text = std::str::from_utf8(&event).unwrap();
        let error: Value =
            serde_json::from_str(text.trim().strip_prefix("data: ").unwrap()).unwrap();
        assert_eq!(error["error"]["code"], code);
        assert!(!text.contains("private internal details"));
        assert!(body.next().await.is_none());
    }
}

#[tokio::test]
async fn inner_sse_fragments_are_relayed_without_comments_between_them() {
    let (send, recv) = oneshot::channel();
    let response = shell(async move {
        let _ = recv.await;
        Ok(sse(Body::from_stream(async_stream::stream! {
            yield Ok::<_, std::io::Error>(Bytes::from_static(b"data: {\"candidates\":"));
            tokio::time::sleep(Duration::from_millis(20)).await;
            yield Ok(Bytes::from_static(b"[]}\n\n"));
        })))
    })
    .await;
    let mut body = response.into_body().into_data_stream();
    assert_eq!(body.next().await.unwrap().unwrap().as_ref(), COMMENT);
    send.send(()).unwrap();
    assert_eq!(
        body.next().await.unwrap().unwrap(),
        "data: {\"candidates\":"
    );
    assert_eq!(body.next().await.unwrap().unwrap(), "[]}\n\n");
    assert!(body.next().await.is_none());
}

#[tokio::test]
async fn non_sse_success_is_reported_as_error_after_heartbeat_commit() {
    let (send, recv) = oneshot::channel();
    let drained = Arc::new(AtomicUsize::new(0));
    let observed = drained.clone();
    let response = shell(async move {
        let _ = recv.await;
        Ok(LocalExecutionRequestOutcome::responded(Response::new(
            Body::from_stream(async_stream::stream! {
                yield Ok::<_, std::io::Error>(Bytes::from_static(b"not SSE"));
                tokio::task::yield_now().await;
                observed.store(1, Ordering::SeqCst);
            }),
        )))
    })
    .await;
    let mut body = response.into_body().into_data_stream();
    let _ = body.next().await;
    send.send(()).unwrap();
    let data = body.next().await.unwrap().unwrap();
    assert!(String::from_utf8_lossy(&data).contains("\"code\":502"));
    assert!(body.next().await.is_none());
    assert_eq!(
        drained.load(Ordering::SeqCst),
        1,
        "invalid response must drain to its finalizer"
    );
}

#[tokio::test]
async fn disconnect_policy_cancels_or_drains_without_releasing_admission_early() {
    for cancel in [true, false] {
        let gate = aether_runtime::ConcurrencyGate::new("heartbeat_test", 1);
        let permit = gate.try_acquire().unwrap();
        let (send, recv) = oneshot::channel::<()>();
        let response = crate::request_lifecycle::run_request(async move {
            crate::request_lifecycle::configure_client_disconnect(
                aether_routing_core::RoutingExecutionPolicy {
                    cancel_on_client_disconnect: cancel,
                    ..Default::default()
                },
            );
            Ok(shell(async move {
                let _permit = permit;
                let _ = recv.await;
                Ok(sse(Body::empty()))
            })
            .await)
        })
        .await
        .unwrap();
        assert_eq!(gate.snapshot().in_flight, 1);
        drop(response);
        if cancel {
            assert!(send.send(()).is_err());
        } else {
            assert_eq!(gate.snapshot().in_flight, 1);
            send.send(()).unwrap();
        }
        tokio::time::timeout(Duration::from_secs(1), async {
            while gate.snapshot().in_flight != 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }
}

#[tokio::test]
async fn diagnostics_survive_response_handoff() {
    let (send, recv) = oneshot::channel::<()>();
    let response = crate::request_diagnostics::scope_request_diagnostics(async move {
        crate::request_diagnostics::record_request_accepted_at(std::time::Instant::now());
        shell(async move {
            let _ = recv.await;
            assert!(crate::request_diagnostics::current_request_diagnostics()
                .unwrap()
                .request_accepted_at()
                .is_some());
            Ok(sse(Body::empty()))
        })
        .await
    })
    .await;
    send.send(()).unwrap();
    to_bytes(response.into_body(), 1024).await.unwrap();
}

#[tokio::test]
async fn deferred_redaction_restores_actual_winner_across_chunk_boundaries() {
    let masked = crate::privacy::mask_chat_request_json(
        br#"{"messages":[{"role":"user","content":"alice@example.com"}]}"#,
        crate::privacy::RedactionSessionConfig::new(b"heartbeat-redaction-test".to_vec(), 300, 600),
    );
    let sentinel = masked
        .session
        .sentinel_for_original("alice@example.com")
        .unwrap()
        .to_string();
    let slot = crate::privacy::RedactionSessionSlot::default();
    slot.put_for_candidate("winner", masked.session);
    let mut request_parts = parts();
    request_parts.extensions.insert(slot.clone());
    let (send, recv) = oneshot::channel::<()>();
    let outcome = execute_with_timing(
        AppState::new().unwrap(),
        request_parts,
        "redaction-test".into(),
        decision(),
        async move {
            let _ = recv.await;
            let data = format!(
                "data: {}\n\n",
                json!({"candidates":[{"content":{"parts":[{"text":sentinel}]}}]})
            );
            let split = data.len() / 2;
            let mut response = Response::builder()
                .header(http::header::CONTENT_TYPE, "text/event-stream")
                .header(crate::constants::CONTROL_CANDIDATE_ID_HEADER, "winner")
                .body(Body::from_stream(futures_util::stream::iter([
                    Ok::<_, std::io::Error>(Bytes::copy_from_slice(&data.as_bytes()[..split])),
                    Ok(Bytes::copy_from_slice(&data.as_bytes()[split..])),
                ])))
                .unwrap();
            response
                .extensions_mut()
                .insert(crate::privacy::RedactionExecutionCandidateId::new("winner"));
            Ok(LocalExecutionRequestOutcome::responded(response))
        },
        GRACE,
        INTERVAL,
    )
    .await
    .unwrap();
    let LocalExecutionRequestOutcome::Responded(response) = outcome else {
        panic!("response expected")
    };
    // The normal proxy restoration pass must defer rather than consume a
    // session before the actual winning response becomes available.
    let response = crate::privacy::restore_stream_response(response, &slot).unwrap();
    send.send(()).unwrap();
    let data = to_bytes(response.into_body(), 4096).await.unwrap();
    let text = String::from_utf8(data.to_vec()).unwrap();
    assert!(text.contains("alice@example.com"));
    assert!(!text.contains("AETHER_"));
}
