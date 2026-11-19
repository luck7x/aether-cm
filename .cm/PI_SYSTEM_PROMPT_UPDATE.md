# Antigravity Pi system prompt filter

For Antigravity requests only, the request envelope builder removes the entire
`systemInstruction` / `system_instruction` field when a text part starts with a
recognized Pi identity. This includes Pi's additional rules and tool descriptions
inside that system instruction. Explicit `tools`, user messages, conversation
history, generation settings and non-Pi system instructions remain untouched.

Recognized openings:

- `You are a coding assistant running inside pi, a coding agent harness.`
- `You are a coding assistant working in a command-line environment.` followed
  by `Help users inspect files, run commands, and modify code.`

The second signature includes the next sentence because its first sentence alone
is too generic. Matching tolerates case and whitespace. Only openings are matched;
quoted identity examples elsewhere in a text part are not changed. No official
agy system prompt is injected, and this filter does not reproduce the real CLI's
session or authentication behavior. A successful build is not evidence that an
upstream 429 is resolved; verify with a real Pi request after deployment.

The filter is enabled by default. Set
`AETHER_ANTIGRAVITY_PI_SYSTEM_PROMPT_FILTER=false` in the existing local service
environment and restart the service to disable it. Runtime changes to this file
are never uploaded to GitHub.

## Validation and deployment

All Rust formatting, compilation, tests and release packaging run in GitHub
Actions. Production performs only lightweight source inspection, authenticated
artifact download, streaming checksum verification, extraction and deployment.

The compatible-binary installer is for this backend-only change. It retains the
old program and exact deployed frontend, uses the same database, requires zero
pending migrations, briefly restarts the single gateway, and checks health,
readiness and the running executable digest. On failure it restores the old
program automatically. It does not build, run migrations, back up/clone/restore
databases, start a second application instance or invoke the blue-green installer.

Run the installer through a detached systemd oneshot, since restarting the gateway
can interrupt the assistant connection. The worker must validate the exact
successful workflow commit and GitHub artifact digest before providing
`AETHER_VERIFIED_BINARY`, `AETHER_EXPECTED_BUILD_SHA` and
`AETHER_EXPECTED_GATEWAY_SHA256`. Rollback instructions are written to
`/root/aether-compatible-update/<run>/rollback.sh` and the successful run is recorded
in `/root/aether-compatible-update/last-success`.
