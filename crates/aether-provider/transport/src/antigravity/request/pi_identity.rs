use std::sync::OnceLock;

use regex::Regex;
use serde_json::{Map, Value};

const FILTER_ENV: &str = "AETHER_ANTIGRAVITY_PI_SYSTEM_PROMPT_FILTER";

pub(super) fn filter_system_instruction(request: &mut Map<String, Value>) {
    let setting = std::env::var(FILTER_ENV).ok();
    filter_with_setting(request, setting.as_deref());
}

fn filter_with_setting(request: &mut Map<String, Value>, setting: Option<&str>) {
    if setting.is_some_and(|value| {
        matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "off" | "no"
        )
    }) {
        return;
    }

    // A recognized Pi opening identifies the entire client system instruction.
    // Remove that field as requested; never rewrite user history or tool data.
    // The old generic opening also needs Pi's following Help sentence to avoid
    // identifying an unrelated custom system prompt by its first sentence alone.
    static OPENING: OnceLock<Regex> = OnceLock::new();
    let opening = OPENING.get_or_init(|| {
        Regex::new(concat!(
            r"(?i)\A\s*You\s+are\s+a\s+coding\s+assistant\s+",
            r"(?:running\s+inside\s+pi,\s*a\s+coding\s+agent\s+harness\.|",
            r"working\s+in\s+a\s+command-line\s+environment\.\s*",
            r"Help\s+users\s+inspect\s+files,\s*run\s+commands,\s*and\s+modify\s+code\.)"
        ))
        .expect("static Pi identity pattern must be valid")
    });
    for key in ["systemInstruction", "system_instruction"] {
        let is_pi = request
            .get(key)
            .and_then(|instruction| instruction.get("parts"))
            .and_then(Value::as_array)
            .is_some_and(|parts| {
                parts.iter().any(|part| {
                    part.get("text")
                        .and_then(Value::as_str)
                        .is_some_and(|text| opening.is_match(text))
                })
            });
        if is_pi {
            request.remove(key);
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::filter_with_setting;
    use crate::antigravity::auth::AntigravityRequestAuth;
    use crate::antigravity::request::{
        build_antigravity_safe_v1internal_request, AntigravityEnvelopeRequestType,
        AntigravityRequestEnvelopeSupport,
    };

    const HELP: &str = "Help users inspect files, run commands, and modify code.";
    const OLD: &str = "You are a coding assistant working in a command-line environment.";
    const NEW: &str = "You are a coding assistant running inside pi, a coding agent harness.";

    #[test]
    fn entire_pi_system_instruction_is_removed_without_changing_history_or_tools() {
        for identity in [OLD, NEW] {
            for key in ["systemInstruction", "system_instruction"] {
                let text = format!("{identity} {HELP}\n\n<tools>read, edit</tools>\nMy rules.");
                let mut body = json!({
                    (key): {"parts": [{"text": text}, {"text": "More Pi rules."}]},
                    "contents": [{"role": "user", "parts": [{"text": text}]}],
                    "tools": [{"functionDeclarations": [{"name": "read", "description": text}]}],
                    "toolConfig": {"functionCallingConfig": {"mode": "AUTO"}},
                    "generationConfig": {"maxOutputTokens": 8192}
                });
                let mut expected = body.clone();
                expected.as_object_mut().unwrap().remove(key);
                filter_with_setting(body.as_object_mut().unwrap(), None);
                assert_eq!(body, expected);
                filter_with_setting(body.as_object_mut().unwrap(), None);
                assert_eq!(body, expected);
            }
        }
    }

    #[test]
    fn switch_disables_filter_without_changing_process_environment() {
        for setting in ["0", "false", "OFF", " no "] {
            let mut body = json!({"systemInstruction": {"parts": [{"text": NEW}]}});
            let original = body.clone();
            filter_with_setting(body.as_object_mut().unwrap(), Some(setting));
            assert_eq!(body, original);
        }
        for setting in [None, Some(""), Some("true"), Some("unknown")] {
            let mut body = json!({"systemInstruction": {"parts": [{"text": NEW}]}});
            filter_with_setting(body.as_object_mut().unwrap(), setting);
            assert_eq!(body, json!({}));
        }
    }

    #[test]
    fn unrelated_quoted_or_malformed_instructions_are_preserved() {
        for instruction in [
            json!({"parts": [{"text": "You are Antigravity, a coding assistant."}]}),
            json!({"parts": [{"text": "You are a coding assistant working in a command-line environment. Keep this custom prompt."}]}),
            json!({"parts": [{"text": format!("Quoted example: {NEW} {HELP}")}]}),
            json!({"parts": [{"inlineData": {"data": "example"}}, null, {"text": 123}]}),
            json!({"parts": "not an array"}),
            json!("not an instruction object"),
            json!(null),
        ] {
            let mut body = json!({"systemInstruction": instruction});
            let original = body.clone();
            filter_with_setting(body.as_object_mut().unwrap(), None);
            assert_eq!(body, original);
        }
    }

    #[test]
    fn pi_opening_in_separate_part_and_both_aliases_are_recognized() {
        let mut body = json!({
            "systemInstruction": {"parts": [{"text": "  YOU are a coding assistant running\ninside pi, a coding agent harness."}, {"text": HELP}]},
            "system_instruction": {"parts": [{"text": format!("{OLD} {HELP}")}]}
        });
        filter_with_setting(body.as_object_mut().unwrap(), None);
        assert_eq!(body, json!({}));
    }

    #[test]
    fn wrapped_and_plain_requests_drop_pi_system_instruction_before_enveloping() {
        let auth = AntigravityRequestAuth {
            project_id: "test-project".to_string(),
            client_version: None,
            session_id: None,
        };
        for wrapped in [false, true] {
            for request_type in [
                AntigravityEnvelopeRequestType::Agent,
                AntigravityEnvelopeRequestType::Checkpoint,
            ] {
                let inner = json!({
                    "systemInstruction": {"parts": [{"text": format!("{NEW} {HELP}\nMy rules.")}]},
                    "contents": [{"role": "user", "parts": [{"text": "hello"}]}],
                    "tools": [{"googleSearch": {}}]
                });
                let original = inner.clone();
                let body = if wrapped {
                    json!({"request": inner})
                } else {
                    inner
                };
                let AntigravityRequestEnvelopeSupport::Supported(envelope) =
                    build_antigravity_safe_v1internal_request(
                        &auth,
                        "test-request",
                        "gemini-3.8-flash-high",
                        &body,
                        request_type,
                    )
                else {
                    panic!("Pi request should be supported");
                };
                assert!(envelope["request"].get("systemInstruction").is_none());
                assert_eq!(envelope["request"]["contents"], original["contents"]);
                assert_eq!(envelope["request"]["tools"], original["tools"]);
            }
        }
    }
}
