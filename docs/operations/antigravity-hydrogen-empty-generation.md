# Antigravity Hydrogen empty-generation recovery

Some Antigravity responses finish with HTTP 200, an empty model candidate,
input-only usage, and no finish reason. This is not evidence that the
credential cannot serve another request.

The recovery exception is deliberately limited to all of these conditions:

- Native Gemini Generate Content on both sides of a streaming execution.
- The internal `antigravity:v1internal` envelope and the
  `/v1internal:streamGenerateContent` upstream action.
- Exactly `gemini-4-hydrogen` or `gemini-4-hydrogen-sonar`, matching both the
  planner's mapped model and the actual request envelope's model.
- An ordinary agent envelope, without checkpoint/endpoint-test `requestType`.
- HTTP 200 followed by EOF before the stream commit gate accepts content.
- Complete, valid, untruncated SSE containing an empty candidate and positive
  input usage, with total tokens equal to input tokens and no output/thought
  tokens. Empty signature carriers do not count as generated content.
- No finish reason, prompt feedback, error, actual text/reasoning, tool call,
  media, unknown candidate payload, or unfinished/invalid SSE tail.

Recognized failures are recorded as `antigravity_empty_generation` (HTTP 502).
The normal configured failover policy still controls whether to retry. A retry
excludes the credential only within the current request and uses the existing
transfer budgets; it does not retry the same credential again for this failure.
An explicit native Gemini error is retained as the ordinary attempt loop's
fallback if subsequent attempts do not supply a replacement or succeed.

The failed candidate remains failed for audit and usage purposes. Its pool
lease is released, but this request-specific failure does not invalidate shared
affinity, lower credential health/score, write a shared cooldown, change adaptive
limits, or invalidate OAuth. Successful subsequent requests retain their normal
feedback and accounting.

All unmatched responses retain their existing behavior. In particular, Flash,
other models/providers/formats/actions, HTTP 401/403/429/5xx, timeouts, bare
disconnects, malformed records, and responses that already emitted real content
do not use this exception. Existing SSE heartbeat behavior is unchanged.

This is a gateway recovery and isolation fix, not a fix for Google's underlying
generation behavior. It does not modify prompts, truncate history, disable
tools, change model routing, or synthesize successful STOP events.

Regression coverage includes both EOF representations, split input frames,
both allowed models, isolation conditions, explicit stop policies, missing retry
outlets, lease release, unchanged credential health/cooldown, real rate limits,
and normal generated responses. Compiling checks and tests must run in remote
CI; production servers must not compile the project.

References:

- https://github.com/router-for-me/CLIProxyAPI/issues/7536
- https://github.com/router-for-me/CLIProxyAPI/issues/7799
- https://github.com/router-for-me/CLIProxyAPI/pull/7573
