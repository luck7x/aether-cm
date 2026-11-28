# Codex WebSocket interruption compatibility

Codex 0.172.0 sends `response.interrupt` with `response_id` and
`mode=discard_partial_items` when cancelling or steering a response. The gateway
previously parsed every follow-up text event as `response.create`, returning
`expected_response_create` and causing the CLI to abandon the connection.

Interrupts now stay on the physical provider socket that owns the response.
The gateway validates the response identity, mode and default lane, forwards the
control event without planning or billing a new turn, and relays the provider's
acknowledgement and terminal events normally. Provider completion can race an
interrupt, so a completed response in the current connection's proved chain can
also receive the control event. Interrupts disable transparent replay.

Regression coverage in `responses_websocket_e2e` exercises in-flight interruption
with the Codex adapter, continuation on the same connection, interruption after
completion, invalid controls, unknown response identities, and per-create billing.
Builds and compiled tests must run in GitHub Actions; never compile on production.
