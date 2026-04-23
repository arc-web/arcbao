#!/bin/sh
# OpenBao Agent entrypoint — sh/busybox/Alpine variant.
#
# Starts bao agent as a sidecar proxy on 127.0.0.1:8100. The agent handles
# AppRole authentication and token renewal. The main process can fetch any
# secret mid-session via BAO_PROXY_ADDR with no token header needed.
#
# Requirements:
#   - /run/bao-auth/role_id, secret_id, agent.hcl mounted read-only
#   - /usr/local/bin/bao bind-mounted from host
#   - busybox available (wget, sed, sleep, cat)
#   - No python3 or curl required
#
# Usage: replace the "fetch startup secrets" section with your agent's secrets.
set -eu

# Set your agent path — used to select agent-specific secret paths.
# Override via environment variable or hardcode for a single-agent setup.
: "${MY_AGENT_PATH:=my-agent}"

BAO_PROXY="http://127.0.0.1:8100"

log() { printf "[openbao] %s\n" "$*" >&2; }

# ── Stage AppRole creds to a writable tmpfs ──────────────────────────────────
log "staging AppRole creds to /tmp/bao-rw/"
mkdir -p /tmp/bao-rw
cp /run/bao-auth/role_id   /tmp/bao-rw/role_id
cp /run/bao-auth/secret_id /tmp/bao-rw/secret_id
cp /run/bao-auth/agent.hcl /tmp/bao-rw/agent.hcl
busybox chown nobody:nobody /tmp/bao-rw/role_id /tmp/bao-rw/secret_id 2>/dev/null || true
chmod 600 /tmp/bao-rw/role_id /tmp/bao-rw/secret_id

# ── Start bao agent in background ────────────────────────────────────────────
log "starting bao agent (proxy on 127.0.0.1:8100)"
/usr/local/bin/bao agent -config=/tmp/bao-rw/agent.hcl > /tmp/bao-agent.log 2>&1 &

# ── Wait for agent to authenticate ───────────────────────────────────────────
log "waiting for agent to authenticate..."
i=0
until busybox wget -qO- "${BAO_PROXY}/v1/auth/token/lookup-self" > /dev/null 2>&1; do
  i=$((i+1))
  [ $i -lt 60 ] || { log "ERROR: agent auth timed out after 60s"; busybox cat /tmp/bao-agent.log >&2; exit 1; }
  busybox sleep 1
done
log "agent ready and authenticated"

# ── fetch() helper ────────────────────────────────────────────────────────────
# Fetches the "value" field from a KV-v2 secret via the local proxy.
# Uses sed to parse JSON without python3.
fetch() {
  busybox wget -qO- "${BAO_PROXY}/v1/secret/data/$1" \
    | busybox sed -n 's/.*"value":"\([^"]*\)".*/\1/p'
}

# ── Fetch startup secrets ─────────────────────────────────────────────────────
# Replace these with the secrets your agent needs at startup.
log "fetching startup secrets ($MY_AGENT_PATH)"

# Example: agent-specific secrets (path uses MY_AGENT_PATH for multi-agent support)
MY_API_KEY=$(fetch "${MY_AGENT_PATH}/api-key")
MY_TOKEN=$(fetch "${MY_AGENT_PATH}/discord-token")

# Example: shared secrets
PLANE_API_KEY=$(fetch shared/plane-api-key)

# Example: tool/infra secrets
SUPABASE_URL=$(fetch tool-infra/supabase-url)
SUPABASE_SERVICE_KEY=$(fetch tool-infra/supabase-service-key)

# ── Validate all secrets are non-empty ────────────────────────────────────────
for v in MY_API_KEY MY_TOKEN PLANE_API_KEY SUPABASE_URL SUPABASE_SERVICE_KEY; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { log "ERROR: $v is empty"; exit 1; }
done
log "all secrets populated"

# ── Export env vars ───────────────────────────────────────────────────────────
export MY_API_KEY MY_TOKEN PLANE_API_KEY SUPABASE_URL SUPABASE_SERVICE_KEY
export BAO_PROXY_ADDR="$BAO_PROXY"

# ── Hand off to main process ──────────────────────────────────────────────────
# Replace with your agent's actual start command.
log "starting main process"
exec /your/agent/start command
