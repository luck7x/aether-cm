use std::convert::Infallible;
use std::sync::{Arc, Mutex};

use axum::body::{to_bytes, Body, Bytes};
use axum::response::Response;
use axum::routing::any;
use axum::{extract::Request, Json, Router};
use http::header::{HeaderName, HeaderValue};
use http::StatusCode;
use serde_json::json;

use crate::constants::{
    CONTROL_EXECUTED_HEADER, CONTROL_EXECUTE_FALLBACK_HEADER, DEPENDENCY_REASON_HEADER,
    EXECUTION_PATH_EXECUTION_RUNTIME_STREAM, EXECUTION_PATH_EXECUTION_RUNTIME_SYNC,
    EXECUTION_PATH_HEADER, EXECUTION_PATH_LOCAL_EXECUTION_RUNTIME_MISS,
    LOCAL_EXECUTION_RUNTIME_MISS_REASON_HEADER, TRACE_ID_HEADER,
};

use super::{
    build_router, build_router_with_execution_runtime_override, build_router_with_state,
    build_state_with_execution_runtime_override, start_server, strip_sse_keepalive_comments,
    wait_until, AppState, FrontdoorCorsConfig, FrontdoorUserRpmConfig, GatewayFallbackMetricKind,
    GatewayFallbackReason, UsageRuntimeConfig, VideoTaskTruthSourceMode,
};
use aether_crypto::{encrypt_python_fernet_plaintext, DEVELOPMENT_ENCRYPTION_KEY};
use aether_data::repository::auth::{
    InMemoryAuthApiKeySnapshotRepository, StoredAuthApiKeySnapshot,
};
use aether_data::repository::candidate_selection::InMemoryMinimalCandidateSelectionReadRepository;
use aether_data::repository::candidates::InMemoryRequestCandidateRepository;
use aether_data::repository::provider_catalog::InMemoryProviderCatalogReadRepository;
use aether_data_contracts::repository::candidate_selection::{
    StoredMinimalCandidateSelectionRow, StoredProviderModelMapping,
};
use aether_data_contracts::repository::candidates::{
    RequestCandidateReadRepository, RequestCandidateStatus,
};
use aether_data_contracts::repository::provider_catalog::{
    StoredProviderCatalogEndpoint, StoredProviderCatalogKey, StoredProviderCatalogProvider,
};
use sha2::{Digest, Sha256};

const STREAM_PROVIDER_GEMINI_TEST_STACK_BYTES: usize = 16 * 1024 * 1024;

fn run_stream_provider_gemini_test<F, Fut>(test_name: &'static str, make_future: F)
where
    F: FnOnce() -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + 'static,
{
    let handle = std::thread::Builder::new()
        .name(test_name.to_string())
        .stack_size(STREAM_PROVIDER_GEMINI_TEST_STACK_BYTES)
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("test runtime should build");
            runtime.block_on(make_future());
        })
        .expect("stream provider gemini test thread should spawn");

    if let Err(payload) = handle.join() {
        std::panic::resume_unwind(payload);
    }
}

mod local_chat;
mod local_cli;

fn with_heartbeat_policy(
    data: crate::data::GatewayDataState,
    enabled: bool,
) -> crate::data::GatewayDataState {
    use aether_data::repository::routing_profiles::InMemoryRoutingGroupRepository;
    use aether_data_contracts::repository::routing_profiles::{
        StoredRoutingGroup, StoredRoutingGroupBinding, StoredRoutingGroupVersion,
    };

    data.with_routing_group_repository_for_tests(Arc::new(InMemoryRoutingGroupRepository::seed(
        [StoredRoutingGroup {
            id: "heartbeat-test-default".into(),
            name: "heartbeat-test-default".into(),
            description: None,
            enabled: true,
            is_system_default: true,
            sort_order: 0,
            config_json: json!({"default_policy": {"enable_cf_heartbeat": enabled}}),
            version: 1,
            created_at: 1,
            updated_at: 1,
            published_at: Some(1),
        }],
        std::iter::empty::<StoredRoutingGroupBinding>(),
        std::iter::empty::<StoredRoutingGroupVersion>(),
    )))
}

async fn read_after_early_heartbeat(
    mut response: reqwest::Response,
    release: &tokio::sync::Notify,
) -> String {
    let first = tokio::time::timeout(std::time::Duration::from_secs(2), response.chunk())
        .await
        .expect("heartbeat must arrive while the upstream is still blocked")
        .expect("first chunk should read")
        .expect("heartbeat chunk must exist");
    assert_eq!(first.as_ref(), b": aether-keepalive\n\n");
    assert_eq!(response.headers()["content-type"], "text/event-stream");
    assert_eq!(response.headers()["x-accel-buffering"], "no");
    release.notify_one();
    let mut body = first.to_vec();
    while let Some(chunk) = response.chunk().await.expect("body should read") {
        body.extend_from_slice(&chunk);
    }
    String::from_utf8(body).expect("SSE must be UTF-8")
}
