use std::collections::BTreeMap;

use axum::body::{Body, Bytes};
use axum::http::Response;
use futures_util::StreamExt;

use super::{RedactionSessionSlot, StreamingResponseRestorer};
use crate::constants::CONTROL_CANDIDATE_ID_HEADER;
use crate::GatewayError;

/// A heartbeat response has no winning candidate yet. Restore its eventual
/// inner response after candidate selection, not the outer heartbeat shell.
#[derive(Clone, Copy, Debug)]
pub(crate) struct DeferredStreamRestoration;

pub(crate) fn restore_stream_response(
    response: Response<Body>,
    redaction_slot: &RedactionSessionSlot,
) -> Result<Response<Body>, GatewayError> {
    if response
        .extensions()
        .get::<DeferredStreamRestoration>()
        .is_some()
    {
        return Ok(response);
    }
    let (mut parts, body) = response.into_parts();
    let candidate_id = parts
        .headers
        .get(CONTROL_CANDIDATE_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let Some(session) = redaction_slot.take_for_candidate(candidate_id) else {
        return Ok(Response::from_parts(parts, body));
    };
    let connection_declared = aether_http::connection_declared_header_names(
        parts
            .headers
            .get_all(http::header::CONNECTION)
            .iter()
            .filter_map(|value| value.to_str().ok()),
    );
    let headers = parts
        .headers
        .iter()
        .filter_map(|(name, value)| {
            let name = name.as_str().to_ascii_lowercase();
            if crate::headers::should_skip_response_header(&name)
                || connection_declared.contains(&name)
            {
                return None;
            }
            value.to_str().ok().map(|value| (name, value.to_string()))
        })
        .collect::<BTreeMap<_, _>>();
    let _ = StreamingResponseRestorer::new(&headers, &session)?;
    parts.headers.clear();
    for (name, value) in &headers {
        parts.headers.insert(
            http::HeaderName::from_bytes(name.as_bytes())
                .map_err(|error| GatewayError::Internal(error.to_string()))?,
            http::HeaderValue::from_str(value)
                .map_err(|error| GatewayError::Internal(error.to_string()))?,
        );
    }
    parts.headers.remove(http::header::CONTENT_LENGTH);
    let stream = async_stream::stream! {
        let mut restorer = match StreamingResponseRestorer::new(&headers, &session) {
            Ok(restorer) => restorer,
            Err(error) => {
                yield Err(std::io::Error::other(format!("{error:?}")));
                return;
            }
        };
        let mut source = body.into_data_stream();
        while let Some(chunk) = source.next().await {
            match chunk {
                Ok(chunk) => match restorer.push_chunk(chunk.as_ref()) {
                    Ok(restored) if restored.is_empty() => {}
                    Ok(restored) => yield Ok(Bytes::from(restored)),
                    Err(error) => {
                        yield Err(std::io::Error::other(format!("{error:?}")));
                        return;
                    }
                },
                Err(error) => {
                    yield Err(std::io::Error::other(error.to_string()));
                    return;
                }
            }
        }
        match restorer.finish() {
            Ok(restored) if restored.is_empty() => {}
            Ok(restored) => yield Ok(Bytes::from(restored)),
            Err(error) => yield Err(std::io::Error::other(format!("{error:?}"))),
        }
    };
    Ok(Response::from_parts(parts, Body::from_stream(stream)))
}
