use super::*;

#[tokio::test]
async fn management_groups_are_admin_only_exclusive_versioned_and_do_not_change_providers() {
    let repository = Arc::new(InMemoryProviderCatalogReadRepository::seed(
        vec![sample_provider("provider-1", "custom", 17)],
        vec![],
        vec![],
    ));
    let original = repository.list_providers(false).await.unwrap();
    let initial = json!({"version": 0, "groups": [{
        "id": "00000000-0000-0000-0000-000000000001", "name": "old", "provider_ids": ["removed"]
    }]})
    .to_string();
    let data = GatewayDataState::with_provider_catalog_repository_for_tests(repository.clone())
        .with_system_config_values_for_tests(vec![(
            "provider_management_groups".to_string(),
            json!(initial),
        )]);
    let gateway = build_router_with_state(AppState::new().unwrap().with_data_state_for_tests(data));
    let (url, handle) = start_server(gateway).await;
    let client = reqwest::Client::new();
    let path = format!("{url}/api/admin/provider-management-groups");
    let anonymous = client.get(&path).send().await.unwrap();
    assert!(matches!(
        anonymous.status(),
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
    ));
    let request = |method| {
        client
            .request(method, &path)
            .header(GATEWAY_HEADER, "rust-phase3b")
            .header(TRUSTED_ADMIN_USER_ID_HEADER, "admin-user-123")
            .header(TRUSTED_ADMIN_USER_ROLE_HEADER, "admin")
            .header(TRUSTED_ADMIN_SESSION_ID_HEADER, "session-123")
    };
    let a = uuid::Uuid::new_v4().to_string();
    let b = uuid::Uuid::new_v4().to_string();
    let doc = json!({"version": 0, "groups": [
        {"id": a, "name": " 免费 ", "provider_ids": ["provider-1", "removed"]},
        {"id": b, "name": "付费", "provider_ids": []}
    ]});
    let response = request(http::Method::PUT).json(&doc).send().await.unwrap();
    let status = response.status();
    let saved: serde_json::Value = response.json().await.unwrap();
    assert_eq!(status, StatusCode::OK, "{saved}");
    assert_eq!(saved["version"], 1);
    assert_eq!(saved["groups"][0]["name"], "免费");
    assert_eq!(saved["groups"][0]["provider_ids"], json!(["provider-1"]));
    assert_eq!(
        request(http::Method::PUT)
            .json(&doc)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::CONFLICT
    );

    let mut duplicate = saved.clone();
    duplicate["groups"][1]["provider_ids"] = json!(["provider-1"]);
    assert_eq!(
        request(http::Method::PUT)
            .json(&duplicate)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::BAD_REQUEST
    );
    duplicate["groups"][1]["provider_ids"] = json!(["missing-provider"]);
    assert_eq!(
        request(http::Method::PUT)
            .json(&duplicate)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::BAD_REQUEST
    );

    // Moving to a different group and deleting the original group are directory-only operations.
    let moved = json!({"version": 1, "groups": [{"id": b, "name": "付费", "provider_ids": ["provider-1"]}]});
    assert_eq!(
        request(http::Method::PUT)
            .json(&moved)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    let current: serde_json::Value = request(http::Method::GET)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(current["version"], 2);
    assert_eq!(current["groups"], moved["groups"]);
    let left = request(http::Method::PUT).json(&current).send();
    let right = request(http::Method::PUT).json(&current).send();
    let (left, right) = tokio::join!(left, right);
    let mut statuses = [
        left.unwrap().status().as_u16(),
        right.unwrap().status().as_u16(),
    ];
    statuses.sort();
    assert_eq!(statuses, [200, 409]);
    let providers = repository.list_providers(false).await.unwrap();
    assert_eq!(
        serde_json::to_value(providers).unwrap(),
        serde_json::to_value(original).unwrap()
    );
    handle.abort();
}
