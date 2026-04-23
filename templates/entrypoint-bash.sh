#!/bin/bash
# OpenBao Agent entrypoint — bash/Ubuntu variant.
#
# Starts bao agent as a sidecar proxy on 127.0.0.1:8100. The agent handles
# AppRole authentication and token renewal. The main process can fetch any
# secret mid-session via BAO_PROXY_ADDR with no token header needed.
#
# Requirements:
#   - /run/bao-auth/role_id, secret_id, agent.hcl mounted read-only
#   - /usr/local/bin/bao bind-mounted from host
#   - python3 available in container (for fetch() and health check)
#
# Usage: replace the "fetch startup secrets" section with your agent's secrets.
set -eu

BAO_PROXY="http://127.0.0.1:8100"

log() { printf "[openbao] %s\n" "$*" >&2; }

# ── Stage AppRole creds to a writable tmpfs ──────────────────────────────────
# bao agent needs write access to the directory containing its config
# (it writes a token sink file). /run/bao-auth is mounted read-only,
# so we copy to /tmp/bao-rw/ first.
log "staging AppRole creds to /tmp/bao-rw/"
mkdir -p /tmp/bao-rw
cp /run/bao-auth/role_id   /tmp/bao-rw/role_id
cp /run/bao-auth/secret_id /tmp/bao-rw/secret_id
cp /run/bao-auth/agent.hcl /tmp/bao-rw/agent.hcl
chmod 600 /tmp/bao-rw/role_id /tmp/bao-rw/secret_id

# ── Start bao agent in background ────────────────────────────────────────────
log "starting bao agent (proxy on 127.0.0.1:8100)"
/usr/local/bin/bao agent -config=/tmp/bao-rw/agent.hcl > /tmp/bao-agent.log 2>&1 &

# ── Wait for agent to authenticate ───────────────────────────────────────────
log "waiting for agent to authenticate..."
i=0
until python3 -c "
import urllib.request
urllib.request.urlopen('${BAO_PROXY}/v1/auth/token/lookup-self', timeout=2)
" > /dev/null 2>&1; do
  i=$((i+1))
  [ $i -lt 60 ] || { log "ERROR: agent auth timed out after 60s"; cat /tmp/bao-agent.log >&2; exit 1; }
  sleep 1
done
log "agent ready and authenticated"

# ── fetch() helper ────────────────────────────────────────────────────────────
# Fetches a secret value from the proxy. Argument is the KV path (no leading /).
# Returns the value of the "value" field from the KV-v2 response.
fetch() {
  BAO_PROXY_ADDR="$BAO_PROXY" SECRET_PATH="$1" python3 << 'PY'
import os, urllib.request, json, sys
addr = os.environ["BAO_PROXY_ADDR"]
path = os.environ["SECRET_PATH"].lstrip("/")
req = urllib.request.Request(addr + "/v1/secret/data/" + path)
try:
    r = json.loads(urllib.request.urlopen(req, timeout=15).read())
    print(r["data"]["data"]["value"])
except Exception as e:
    print(f"ERR: {e}", file=sys.stderr)
    sys.exit(2)
PY
}

# ── Fetch startup secrets ─────────────────────────────────────────────────────
# Replace these with the secrets your agent needs at startup.
# All secrets are fetched through the local proxy — no token header needed.
log "fetching startup secrets"

# Example: agent-specific secrets
MY_API_KEY=$(fetch my-agent/api-key)
MY_TOKEN=$(fetch my-agent/discord-token)

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
