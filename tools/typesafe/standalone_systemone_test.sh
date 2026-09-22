#!/usr/bin/env bash
set -Eeuo pipefail

# Independent TypeSafe SystemOne smoke test. This intentionally bypasses Aether
# so protocol/auth failures can be separated from gateway routing failures.
readonly BASE_URL="${TYPESAFE_BASE_URL:-https://api.typesafe.ai/v1}"
readonly MODEL="${TYPESAFE_MODEL:-jev-latest}"
readonly API_KEY="${TYPESAFE_API_KEY:-}"

[[ -n "${API_KEY}" ]] || {
  echo 'TYPESAFE_API_KEY is required (not stored by this script)' >&2
  exit 2
}

body="$(jq -cn \
  --arg model "${MODEL}" \
  '{model:$model,state:"Return exactly STANDALONE_TYPESAFE_OK",questions:{model_test:{type:"noul",instructions:"Is this a connectivity test?"}}}')"
tmp_headers="$(mktemp)"
tmp_body="$(mktemp)"
trap 'rm -f "${tmp_headers}" "${tmp_body}"' EXIT

curl --fail-with-body --silent --show-error --max-time 60 \
  -D "${tmp_headers}" -o "${tmp_body}" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H 'Content-Type: application/json' \
  -X POST "${BASE_URL%/}/systemone" \
  --data "${body}"

status="$(awk 'NR==1 {print $2}' "${tmp_headers}")"
jq -e 'type == "object"' "${tmp_body}" >/dev/null
response_keys="$(jq -r 'keys | join(",")' "${tmp_body}")"
echo "TypeSafe standalone SystemOne OK: status=${status} model=${MODEL} response_keys=${response_keys}"
