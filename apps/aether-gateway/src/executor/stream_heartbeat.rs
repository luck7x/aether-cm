use std::collections::BTreeMap;
use std::future::Future;
use std::io::Error as IoError;
use std::time::{Duration, Instant};

use aether_ai_formats::contracts::{GEMINI_CHAT_STREAM_PLAN_KIND, GEMINI_CLI_STREAM_PLAN_KIND};
use axum::body::{Body, Bytes};
use axum::http::StatusCode;
use futures_util::StreamExt;
use serde_json::json;

use super::{
    build_local_execution_runtime_miss_context,
    record_failed_usage_for_deferred_response_with_committed_stream,
    record_failed_usage_for_exhausted_request_with_committed_stream,
    record_failed_usage_for_runtime_miss_request_with_committed_stream,
    CommittedStreamClientResponse, LocalExecutionRequestOutcome,
};
use crate::api::response::build_client_response_from_parts;
use crate::constants::EXECUTION_PATH_LOCAL_EXECUTION_RUNTIME_MISS;
use crate::control::GatewayControlDecision;
use crate::privacy::{DeferredStreamRestoration, RedactionSessionSlot};
use crate::request_diagnostics::{current_request_diagnostics, scope_request_diagnostics_with};
use crate::{AppState, GatewayError};

const GRACE: Duration = Duration::from_secs(1);
const INTERVAL: Duration = Duration::from_secs(15);
const COMMENT: &[u8] = b": aether-keepalive\n\n";

pub(super) fn should_wrap(
    parts: &http::request::Parts,
    plan_kind: &str,
    policy: Option<aether_routing_core::RoutingExecutionPolicy>,
) -> bool {
    let gemini = matches!(
        plan_kind,
        GEMINI_CHAT_STREAM_PLAN_KIND | GEMINI_CLI_STREAM_PLAN_KIND
    );
    let sse = parts.uri.query().is_some_and(|query| {
        url::form_urlencoded::parse(query.as_bytes())
            .any(|(key, value)| key == "alt" && value == "sse")
    }) || parts
        .headers
        .get(http::header::ACCEPT)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| {
            value.split(',').any(|kind| {
                kind.split(';')
                    .next()
                    .is_some_and(|kind| kind.trim().eq_ignore_ascii_case("text/event-stream"))
            })
        });
    gemini && sse && policy.is_some_and(|policy| policy.enable_cf_heartbeat)
}

pub(super) async fn execute_with_heartbeat<F>(
    state: AppState,
    parts: http::request::Parts,
    trace_id: String,
    decision: GatewayControlDecision,
    execute: F,
) -> Result<LocalExecutionRequestOutcome, GatewayError>
where
    F: Future<Output = Result<LocalExecutionRequestOutcome, GatewayError>> + Send + 'static,
{
    execute_with_timing(state, parts, trace_id, decision, execute, GRACE, INTERVAL).await
}

async fn execute_with_timing<F>(
    state: AppState,
    parts: http::request::Parts,
    trace_id: String,
    decision: GatewayControlDecision,
    execute: F,
    grace: Duration,
    interval: Duration,
) -> Result<LocalExecutionRequestOutcome, GatewayError>
where
    F: Future<Output = Result<LocalExecutionRequestOutcome, GatewayError>> + Send + 'static,
{
    let started = Instant::now();
    let diagnostics = current_request_diagnostics();
    let mut pending = Box::pin(scope_request_diagnostics_with(diagnostics.clone(), execute));
    // Preserve status, headers, extensions and fallback semantics for fast
    // responses. After the grace period HTTP status is committed as 200;
    // subsequent failures must be delivered as native Gemini SSE errors.
    if let Ok(outcome) = tokio::time::timeout(grace, &mut pending).await {
        return outcome;
    }
    let redaction = parts.extensions.get::<RedactionSessionSlot>().cloned();
    let execution_trace_id = trace_id.clone();
    let execution_decision = decision.clone();
    let cleanup = RuntimeMissCleanup(state.clone(), trace_id.clone());
    let body = async_stream::stream! {
        // Keep admission and request extensions alive until this body finishes.
        // The request lifecycle drains or drops this future on disconnect using
        // its existing policy; no detached worker or unbounded queue is needed.
        let _cleanup = cleanup;
        yield Ok::<Bytes, IoError>(Bytes::from_static(COMMENT));
        let result = loop {
            tokio::select! {
                biased;
                result = &mut pending => break result,
                _ = tokio::time::sleep(interval) => {
                    yield Ok(Bytes::from_static(COMMENT));
                }
            }
        };
        let response = match result {
            Ok(LocalExecutionRequestOutcome::Responded(response)) => response,
            Ok(LocalExecutionRequestOutcome::Exhausted(exhaustion)) => {
                let event = error_event(503, "All upstream candidates failed. Please retry.");
                let diagnostic = state.take_local_execution_runtime_miss_diagnostic(&execution_trace_id);
                scope_request_diagnostics_with(diagnostics.clone(), record_failed_usage_for_exhausted_request_with_committed_stream(
                    &state, exhaustion, &started, "Gemini stream exhausted all candidates",
                    EXECUTION_PATH_LOCAL_EXECUTION_RUNTIME_MISS, diagnostic.as_ref(), committed_error(&event),
                )).await;
                yield Ok(event);
                return;
            }
            Ok(LocalExecutionRequestOutcome::NoPath) => {
                let event = error_event(503, "No available upstream route. Please retry.");
                scope_request_diagnostics_with(diagnostics.clone(), record_runtime_miss(
                    &state, &parts, &execution_trace_id, &execution_decision, &started, 503, &event,
                )).await;
                yield Ok(event);
                return;
            }
            Err(_) => {
                let event = error_event(502, "Gateway failed while waiting for the upstream response.");
                scope_request_diagnostics_with(diagnostics.clone(), record_runtime_miss(
                    &state, &parts, &execution_trace_id, &execution_decision, &started, 502, &event,
                )).await;
                yield Ok(event);
                return;
            }
        };
        // The proxy already returned the shell, so it cannot clean up planner
        // diagnostics written by the later execution future.
        state.clear_local_execution_runtime_miss_diagnostic(&execution_trace_id);
        if !response.status().is_success() {
            let status = response.status().as_u16();
            let event = error_event(status, "Upstream request failed. See the request trace for details.");
            scope_request_diagnostics_with(diagnostics, record_failed_usage_for_deferred_response_with_committed_stream(
                &state, &response, committed_error(&event),
            )).await;
            yield Ok(event);
            drain_response(response).await;
            return;
        }
        let is_sse = response.headers().get(http::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.split(';').next().is_some_and(|kind| kind.trim().eq_ignore_ascii_case("text/event-stream")));
        if !is_sse {
            tracing::warn!(event_name = "gemini_heartbeat_non_sse_response", trace_id = %execution_trace_id,
                "Gemini streaming upstream returned an unexpected content type");
            yield Ok(error_event(502, "Upstream did not return the expected SSE response."));
            // Complete the runtime producer and its usage/cost finalizer. A
            // dropped receiver would falsely mark this as client cancellation.
            drain_response(response).await;
            return;
        }
        let response = if let Some(slot) = redaction.as_ref() {
            match crate::privacy::restore_stream_response(response, slot) {
                Ok(response) => response,
                Err(_) => {
                    yield Ok(error_event(502, "Gateway could not restore the stream response."));
                    return;
                }
            }
        } else { response };
        let mut stream = response.into_body().into_data_stream();
        // Once inner SSE has started, never inject between arbitrary body
        // chunks: a chunk boundary may be in the middle of a JSON/data line.
        while let Some(chunk) = stream.next().await {
            match chunk {
                Ok(chunk) => yield Ok(chunk),
                Err(_) => {
                    yield Err(IoError::other("Upstream stream interrupted"));
                    return;
                }
            }
        }
    };
    let mut response = build_client_response_from_parts(
        StatusCode::OK.as_u16(),
        &BTreeMap::from([("content-type".to_string(), "text/event-stream".to_string())]),
        Body::from_stream(body),
        &trace_id,
        Some(&decision),
    )?;
    response.extensions_mut().insert(DeferredStreamRestoration);
    Ok(LocalExecutionRequestOutcome::responded(response))
}

struct RuntimeMissCleanup(AppState, String);

impl Drop for RuntimeMissCleanup {
    fn drop(&mut self) {
        self.0
            .clear_local_execution_runtime_miss_diagnostic(&self.1);
    }
}

fn committed_error(event: &Bytes) -> CommittedStreamClientResponse {
    CommittedStreamClientResponse::gemini_sse_error(String::from_utf8_lossy(event).into_owned())
}

async fn record_runtime_miss(
    state: &AppState,
    parts: &http::request::Parts,
    trace_id: &str,
    decision: &GatewayControlDecision,
    started: &Instant,
    status: u16,
    event: &Bytes,
) {
    let diagnostic = state.take_local_execution_runtime_miss_diagnostic(trace_id);
    let context = build_local_execution_runtime_miss_context(state, trace_id, Some(decision)).await;
    record_failed_usage_for_runtime_miss_request_with_committed_stream(
        state,
        trace_id,
        started,
        "Gemini stream execution failed after heartbeat",
        EXECUTION_PATH_LOCAL_EXECUTION_RUNTIME_MISS,
        Some(decision),
        diagnostic.as_ref(),
        &context,
        &parts.headers,
        None,
        status,
        committed_error(event),
    )
    .await;
}

async fn drain_response(response: axum::http::Response<Body>) {
    let mut body = response.into_body().into_data_stream();
    while body.next().await.is_some() {}
}

fn error_event(code: u16, message: &str) -> Bytes {
    let status = match code {
        400 => "INVALID_ARGUMENT",
        401 => "UNAUTHENTICATED",
        403 => "PERMISSION_DENIED",
        404 => "NOT_FOUND",
        429 => "RESOURCE_EXHAUSTED",
        503 => "UNAVAILABLE",
        504 => "DEADLINE_EXCEEDED",
        _ => "INTERNAL",
    };
    Bytes::from(format!(
        "data: {}\n\n",
        json!({"error": {"code": code, "message": message, "status": status}})
    ))
}

#[cfg(test)]
mod tests;
