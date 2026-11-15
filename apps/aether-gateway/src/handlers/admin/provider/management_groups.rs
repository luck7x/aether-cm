//! Display-only provider organization. This document is never read by scheduling.
use std::collections::HashSet;

use axum::{
    body::{Body, Bytes},
    http::{Method, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::handlers::admin::request::{AdminAppState, AdminRequestContext};
use crate::GatewayError;

pub(crate) const CONFIG_KEY: &str = "provider_management_groups";
const PATH: &str = "/api/admin/provider-management-groups";

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ManagementGroups {
    version: u64,
    groups: Vec<ManagementGroup>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ManagementGroup {
    id: String,
    name: String,
    provider_ids: Vec<String>,
}

impl ManagementGroups {
    fn validate(&mut self) -> Result<(), &'static str> {
        if self.groups.len() > 200 {
            return Err("最多创建 200 个管理分组");
        }
        let mut ids = HashSet::new();
        let mut names = HashSet::new();
        let mut providers = HashSet::new();
        for group in &mut self.groups {
            group.name = group.name.trim().to_string();
            if uuid::Uuid::parse_str(&group.id).is_err() || !ids.insert(group.id.clone()) {
                return Err("管理分组 ID 无效或重复");
            }
            if group.name.is_empty() || group.name.chars().count() > 80 {
                return Err("管理分组名称须为 1 到 80 个字符");
            }
            if !names.insert(group.name.to_lowercase()) {
                return Err("管理分组名称不能重复");
            }
            for id in &group.provider_ids {
                if id.is_empty() || id.len() > 128 || !providers.insert(id.clone()) {
                    return Err("一个提供商只能属于一个管理分组，且组内不能重复");
                }
            }
        }
        if providers.len() > 10_000 {
            return Err("管理分组最多包含 10000 个提供商");
        }
        Ok(())
    }
}

fn error(status: StatusCode, detail: &str) -> Option<Response<Body>> {
    Some((status, Json(json!({ "detail": detail }))).into_response())
}

pub(super) async fn maybe_build_response(
    state: &AdminAppState<'_>,
    context: &AdminRequestContext<'_>,
    body: Option<&Bytes>,
) -> Result<Option<Response<Body>>, GatewayError> {
    if context.path() != PATH || !matches!(*context.method(), Method::GET | Method::PUT) {
        return Ok(None);
    }
    let app = state.app();
    if !app.data.has_system_config_store() {
        return Ok(error(StatusCode::SERVICE_UNAVAILABLE, "管理分组存储不可用"));
    }
    let stored = app.read_system_config_json_value_strong(CONFIG_KEY).await?;
    let Some(raw) = stored.as_ref().and_then(|value| value.as_str()) else {
        return Ok(error(
            StatusCode::SERVICE_UNAVAILABLE,
            "管理分组存储尚未初始化，请完成数据库迁移",
        ));
    };
    let current: ManagementGroups = serde_json::from_str(raw).map_err(|_| {
        GatewayError::Internal("Invalid provider management groups document".into())
    })?;
    if context.method() == Method::GET {
        return Ok(Some(Json(current).into_response()));
    }
    let Some(body) = body.filter(|body| body.len() <= 1024 * 1024) else {
        return Ok(error(
            StatusCode::BAD_REQUEST,
            "管理分组请求为空或超过 1 MiB",
        ));
    };
    let Ok(mut next) = serde_json::from_slice::<ManagementGroups>(body) else {
        return Ok(error(StatusCode::BAD_REQUEST, "管理分组请求格式无效"));
    };
    if next.version != current.version {
        return Ok(error(
            StatusCode::CONFLICT,
            "管理分组已被其他管理员修改，请重新加载后编辑",
        ));
    }
    if let Err(detail) = next.validate() {
        return Ok(error(StatusCode::BAD_REQUEST, detail));
    }
    if !state.has_provider_catalog_data_reader() {
        return Ok(error(StatusCode::SERVICE_UNAVAILABLE, "提供商目录不可用"));
    }
    let providers: HashSet<_> = state
        .list_provider_catalog_providers(false)
        .await?
        .into_iter()
        .map(|provider| provider.id)
        .collect();
    if next
        .groups
        .iter()
        .flat_map(|group| &group.provider_ids)
        .any(|id| !providers.contains(id))
    {
        return Ok(error(
            StatusCode::BAD_REQUEST,
            "包含已删除或不存在的提供商，请刷新目录后重试",
        ));
    }
    next.version = current
        .version
        .checked_add(1)
        .ok_or_else(|| GatewayError::Internal("Management groups version overflow".into()))?;
    let replacement =
        serde_json::to_string(&next).map_err(|err| GatewayError::Internal(err.to_string()))?;
    if !app
        .compare_and_set_system_config_string_value(CONFIG_KEY, raw, &replacement)
        .await?
    {
        return Ok(error(
            StatusCode::CONFLICT,
            "管理分组已被其他管理员修改，请重新加载后编辑",
        ));
    }
    Ok(Some(Json(next).into_response()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn group(name: &str, providers: &[&str]) -> ManagementGroup {
        ManagementGroup {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.into(),
            provider_ids: providers.iter().map(|id| (*id).into()).collect(),
        }
    }

    #[test]
    fn rejects_membership_in_multiple_groups_and_duplicate_names() {
        let mut doc = ManagementGroups {
            version: 0,
            groups: vec![group("free", &["p1"]), group("paid", &["p1"])],
        };
        assert!(doc.validate().is_err());
        doc.groups[1].provider_ids.clear();
        assert!(doc.validate().is_ok());
        doc.groups[1].name = " FREE ".into();
        assert!(doc.validate().is_err());
    }

    #[test]
    fn trims_names_and_rejects_invalid_or_duplicate_group_ids() {
        let mut doc = ManagementGroups {
            version: 0,
            groups: vec![group(" 免费 ", &[])],
        };
        assert!(doc.validate().is_ok());
        assert_eq!(doc.groups[0].name, "免费");
        doc.groups.push(doc.groups[0].clone());
        assert!(doc.validate().is_err());
        doc.groups.truncate(1);
        doc.groups[0].id = "invalid".into();
        assert!(doc.validate().is_err());
    }
}
