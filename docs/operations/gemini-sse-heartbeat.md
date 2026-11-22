# Gemini SSE keepalive during upstream selection

For Gemini chat and CLI streaming requests, enable **CF保持心跳** in the
request's routing strategy (`default_policy.enable_cf_heartbeat`). The request
must explicitly select SSE using `alt=sse` or `Accept: text/event-stream`.

The gateway allows one second for the normal response. Fast responses preserve
their original status, headers and body. If execution is still waiting, the
gateway sends an HTTP 200 SSE response with `: aether-keepalive` comments,
immediately and then every 15 seconds. This covers upstream first-byte waits,
same-key retries and account/provider failover. It prevents an otherwise idle
Cloudflare connection from timing out while those attempts are still running.

When the selected upstream response becomes available, the gateway stops its
outer keepalive and relays the inner SSE chunks unchanged. It never inserts
comments between arbitrary chunks, which may split a JSON event. Existing
runtime stream handling remains responsible for the active model stream.

After the first heartbeat, the HTTP status is committed as 200. A subsequent
failure is represented by a native Gemini SSE error event, for example:

```text
data: {"error":{"code":503,"message":"All upstream candidates failed. Please retry.","status":"UNAVAILABLE"}}

```

Deferred failure usage keeps the semantic error status and separately records
`request_metadata.client_response_status_code=200`, SSE client headers and the
terminal event. Headers that only become known after candidate selection cannot
be added to the already committed response. Unexpected non-SSE upstream bodies
are drained for normal runtime settlement and produce a gateway stream error;
their content is never forwarded into the SSE connection.

The execution future belongs to the response body. The existing routing
`cancel_on_client_disconnect` policy controls cancellation versus background
completion, including admission and usage lifecycle. Privacy restoration waits
for the actual winning candidate before consuming its redaction session.

This option does not alter account priorities, retry counts, model timeouts or
prompt rewriting. It does not apply to OpenAI/Claude streams, file downloads,
or Gemini requests that do not select SSE. It avoids idle transport timeouts;
upstream capacity errors and model failures can still occur.

Build and test on remote CI. Deploy this backend-only change with the compatible
single-service binary installer and its rollback script; no database migration
or frontend replacement is required.
