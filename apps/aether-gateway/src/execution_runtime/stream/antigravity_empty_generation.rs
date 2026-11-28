//! A narrow exception for the observed Hydrogen zero-generation response.
//! This is not a general EOF, transport, or credential failure classifier.

use aether_contracts::ExecutionPlan;
use serde_json::{json, Value};

use super::commit_policy::find_sse_record_boundary;

pub(super) fn empty_generation_error(
    plan: &ExecutionPlan,
    report_context: Option<&Value>,
    status_code: u16,
    body: &[u8],
    truncated: bool,
) -> Option<Value> {
    let context = report_context?;
    let model = context.get("mapped_model")?.as_str()?;
    let envelope = plan.body.json_body.as_ref()?;
    if status_code != 200
        || truncated
        || !plan.stream
        || plan.provider_api_format != "gemini:generate_content"
        || plan.client_api_format != "gemini:generate_content"
        || context.get("envelope_name")?.as_str()? != "antigravity:v1internal"
        || !matches!(model, "gemini-4-hydrogen" | "gemini-4-hydrogen-sonar")
        || envelope.get("model")?.as_str()? != model
        || !envelope.get("request")?.is_object()
        || envelope.get("requestType").is_some()
        || plan.method != "POST"
        || url::Url::parse(&plan.url).ok()?.path() != "/v1internal:streamGenerateContent"
        || !has_only_zero_generation_records(body)
    {
        return None;
    }
    Some(json!({
        "error": {
            "code": 502,
            "status": "INTERNAL",
            "type": "antigravity_empty_generation",
            "message": "Antigravity returned an empty Hydrogen generation without a finish reason",
            "upstream_status": 200
        }
    }))
}

fn zero_or_absent(value: Option<&Value>) -> bool {
    value.is_none_or(|value| value.as_u64() == Some(0))
}

fn empty_part(part: &Value) -> bool {
    let Some(part) = part.as_object() else {
        return false;
    };
    part.iter().all(|(key, value)| match key.as_str() {
        "text" => value.as_str() == Some(""),
        "thoughtSignature" | "thought_signature" => value.is_string(),
        "thought" => value.is_boolean(),
        _ => false,
    })
}

fn has_only_zero_generation_records(mut body: &[u8]) -> bool {
    let mut saw_candidate = false;
    let mut saw_input_only_usage = false;
    while let Some((end, separator)) = find_sse_record_boundary(body) {
        let Ok(record) = std::str::from_utf8(&body[..end]) else {
            return false;
        };
        body = &body[end + separator..];
        let normalized = record.replace("\r\n", "\n").replace('\r', "\n");
        let mut data = Vec::new();
        for line in normalized.lines() {
            if line.is_empty() || line.starts_with(':') {
                continue;
            }
            if let Some(value) = line.strip_prefix("data:") {
                data.push(value.trim_start());
            } else if line != "event: message" {
                // Unknown framing, errors and incomplete records keep the old path.
                return false;
            }
        }
        if data.is_empty() {
            continue;
        }
        let Ok(root) = serde_json::from_str::<Value>(&data.join("\n")) else {
            return false;
        };
        let response = root.get("response").unwrap_or(&root);
        if !response.is_object()
            || root.get("error").is_some()
            || root.get("promptFeedback").is_some()
            || root.get("prompt_feedback").is_some()
            || response.get("error").is_some()
            || response.get("promptFeedback").is_some()
            || response.get("prompt_feedback").is_some()
        {
            return false;
        }
        if let Some(candidates) = response.get("candidates") {
            let Some(candidates) = candidates.as_array() else {
                return false;
            };
            for candidate in candidates {
                let Some(candidate) = candidate.as_object() else {
                    return false;
                };
                if candidate
                    .keys()
                    .any(|key| !matches!(key.as_str(), "content" | "index"))
                {
                    return false;
                }
                let Some(content) = candidate.get("content").and_then(Value::as_object) else {
                    return false;
                };
                if content
                    .keys()
                    .any(|key| !matches!(key.as_str(), "role" | "parts"))
                    || content
                        .get("role")
                        .is_some_and(|role| role.as_str() != Some("model"))
                    || content.get("parts").is_some_and(|parts| {
                        parts
                            .as_array()
                            .is_none_or(|parts| !parts.iter().all(empty_part))
                    })
                {
                    return false;
                }
                saw_candidate = true;
            }
        }
        if let Some(usage) = response.get("usageMetadata") {
            let Some(prompt) = usage.get("promptTokenCount").and_then(Value::as_u64) else {
                return false;
            };
            if prompt == 0
                || usage.get("totalTokenCount").and_then(Value::as_u64) != Some(prompt)
                || !zero_or_absent(usage.get("candidatesTokenCount"))
                || !zero_or_absent(usage.get("thoughtsTokenCount"))
                || usage.get("candidates_token_count").is_some()
                || usage.get("thoughts_token_count").is_some()
            {
                return false;
            }
            saw_input_only_usage = true;
        }
    }
    body.iter().all(u8::is_ascii_whitespace) && saw_candidate && saw_input_only_usage
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan() -> ExecutionPlan {
        serde_json::from_value(json!({
            "request_id": "request-empty-generation-test",
            "provider_id": "provider-test", "endpoint_id": "endpoint-test", "key_id": "key-test",
            "provider_name": "An arbitrary display name", "model_name": "client-model-alias",
            "method": "POST", "url": "https://example.invalid/v1internal:streamGenerateContent?alt=sse",
            "body": {"json_body": {"model": "gemini-4-hydrogen-sonar", "request": {}}},
            "stream": true, "client_api_format": "gemini:generate_content", "provider_api_format": "gemini:generate_content"
        })).unwrap()
    }

    fn context() -> Value {
        json!({"envelope_name":"antigravity:v1internal","mapped_model":"gemini-4-hydrogen-sonar"})
    }

    #[test]
    fn only_exact_antigravity_hydrogen_native_route_is_eligible() {
        let body = sample();
        for model in ["gemini-4-hydrogen", "gemini-4-hydrogen-sonar"] {
            let mut plan = plan();
            plan.body.json_body.as_mut().unwrap()["model"] = json!(model);
            let mut context = context();
            context["mapped_model"] = json!(model);
            assert!(empty_generation_error(&plan, Some(&context), 200, &body, false).is_some());
        }
        let baseline = plan();
        let context = context();
        for status in [204, 400, 401, 403, 429, 500, 502, 503, 504] {
            assert!(
                empty_generation_error(&baseline, Some(&context), status, &body, false).is_none()
            );
        }
        assert!(empty_generation_error(&baseline, Some(&context), 200, &body, true).is_none());
        assert!(empty_generation_error(&baseline, None, 200, &body, false).is_none());
        for changed in 0..8 {
            let mut plan = baseline.clone();
            let mut context = context.clone();
            match changed {
                0 => plan.client_api_format = "openai:responses".into(),
                1 => plan.provider_api_format = "openai:chat".into(),
                2 => context["envelope_name"] = json!("gemini_cli:v1internal"),
                3 => context["mapped_model"] = json!("gemini-3.8-flash"),
                4 => plan.body.json_body.as_mut().unwrap()["model"] = json!("gemini-4-hydrogen"),
                5 => plan.stream = false,
                6 => plan.url = "https://example.invalid/v1internal:generateContent".into(),
                _ => plan.body.json_body.as_mut().unwrap()["requestType"] = json!("endpoint_test"),
            }
            assert!(
                empty_generation_error(&plan, Some(&context), 200, &body, false).is_none(),
                "case {changed}"
            );
        }
        for model in [
            "gemini-3.8-flash",
            "gemini-4-hydrogen-unknown",
            "claude-sonnet-4-6",
        ] {
            let mut plan = baseline.clone();
            let mut context = context.clone();
            plan.body.json_body.as_mut().unwrap()["model"] = json!(model);
            context["mapped_model"] = json!(model);
            assert!(empty_generation_error(&plan, Some(&context), 200, &body, false).is_none());
        }
    }

    fn sample() -> Vec<u8> {
        format!(
            "data: {}\n\n",
            json!({
                "response": {
                    "candidates": [{"content": {"role": "model"}}],
                    "usageMetadata": {"promptTokenCount": 100, "totalTokenCount": 100}
                }
            })
        )
        .into_bytes()
    }

    #[test]
    fn accepts_input_only_empty_candidate_and_signature_only_shells() {
        assert!(has_only_zero_generation_records(&sample()));
        let mut root: Value = serde_json::from_slice(&sample()[6..]).unwrap();
        root["response"]["candidates"][0]["content"]["parts"] =
            json!([{"text": "", "thoughtSignature": "synthetic-test-signature"}]);
        let body = format!("data: {root}\r\n\r\n");
        assert!(has_only_zero_generation_records(body.as_bytes()));
    }

    #[test]
    fn rejects_incomplete_or_malformed_streams_and_real_output() {
        assert!(!has_only_zero_generation_records(b""));
        let mut body = sample();
        body.extend_from_slice(b"data: {broken");
        assert!(!has_only_zero_generation_records(&body));
        for part in [
            json!({"text":"answer"}),
            json!({"thought":true,"text":"reasoning"}),
            json!({"functionCall":{"name":"test_tool","args":{}}}),
            json!({"inlineData":{"mimeType":"image/png","data":"test"}}),
        ] {
            let mut root: Value = serde_json::from_slice(&sample()[6..]).unwrap();
            root["response"]["candidates"][0]["content"]["parts"] = json!([part]);
            assert!(!has_only_zero_generation_records(
                format!("data: {root}\n\n").as_bytes()
            ));
        }
        for field in [
            "finishReason",
            "finish_reason",
            "finishMessage",
            "safetyRatings",
        ] {
            let mut root: Value = serde_json::from_slice(&sample()[6..]).unwrap();
            root["response"]["candidates"][0][field] = json!("STOP");
            assert!(!has_only_zero_generation_records(
                format!("data: {root}\n\n").as_bytes()
            ));
        }
        for field in ["error", "promptFeedback", "prompt_feedback"] {
            let mut root: Value = serde_json::from_slice(&sample()[6..]).unwrap();
            root["response"][field] = json!({"blockReason":"SAFETY"});
            assert!(!has_only_zero_generation_records(
                format!("data: {root}\n\n").as_bytes()
            ));
        }
        for field in ["candidatesTokenCount", "thoughtsTokenCount"] {
            let mut root: Value = serde_json::from_slice(&sample()[6..]).unwrap();
            root["response"]["usageMetadata"][field] = json!(1);
            assert!(!has_only_zero_generation_records(
                format!("data: {root}\n\n").as_bytes()
            ));
        }
    }

    #[test]
    fn requires_complete_input_only_accounting_and_candidate_records() {
        let candidate = "data: {\"response\":{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[]}}]}}\n\n";
        let usage = "data: {\"response\":{\"usageMetadata\":{\"promptTokenCount\":100,\"totalTokenCount\":100}}}\n\n";
        assert!(has_only_zero_generation_records(
            format!(": ping\n\n{candidate}{usage}").as_bytes()
        ));
        assert!(!has_only_zero_generation_records(candidate.as_bytes()));
        assert!(!has_only_zero_generation_records(usage.as_bytes()));
        for value in [json!(null), json!(-1), json!(101), json!("100")] {
            let mut root: Value = serde_json::from_slice(&sample()[6..]).unwrap();
            root["response"]["usageMetadata"]["totalTokenCount"] = value;
            assert!(!has_only_zero_generation_records(
                format!("data: {root}\n\n").as_bytes()
            ));
        }
        let mut root: Value = serde_json::from_slice(&sample()[6..]).unwrap();
        root["response"]["candidates"] = json!([]);
        assert!(!has_only_zero_generation_records(
            format!("data: {root}\n\n").as_bytes()
        ));
        root = serde_json::from_slice(&sample()[6..]).unwrap();
        root["promptFeedback"] = json!({"blockReason":"SAFETY"});
        assert!(!has_only_zero_generation_records(
            format!("data: {root}\n\n").as_bytes()
        ));
        for suffix in [
            "data: [DONE]\n\n",
            "event: error\ndata: {}\n\n",
            "data: {bad}\n\n",
        ] {
            assert!(!has_only_zero_generation_records(
                format!("{candidate}{usage}{suffix}").as_bytes()
            ));
        }
    }
}
