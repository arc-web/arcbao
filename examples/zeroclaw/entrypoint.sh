#!/bin/sh
# OpenBao Agent entrypoint for ZeroClaw — a sh/busybox/Alpine AI agent.
# This is the production entrypoint used by ARC's ZeroClaw agents (alpha + bravo).
#
# ZeroClaw is a Discord AI agent running on Alpine/busybox inside Docker.
# It uses busybox wget + sed for secret fetching (no python3, no curl).
#
# ZEROCLAW_AGENT_PATH selects which agent's secrets:
#   zeroclaw-alpha  or  zeroclaw-bravo
#
# The same entrypoint and image are used for both agents —
# only the mounted credentials and ZEROCLAW_AGENT_PATH differ.
set -eu

: "${ZEROCLAW_AGENT_PATH:?missing - must be zeroclaw-alpha or zeroclaw-bravo}"

PERSIST_DIR="/zeroclaw-data/.zeroclaw"
TMP_DIR="/run/zeroclaw"
BAO_PROXY="http://127.0.0.1:8100"

log() { printf "[openbao-zeroclaw] %s\n" "$*" >&2; }

log "stage AppRole creds to tmpfs (nobody-owned, 600)"
mkdir -p /tmp/bao-rw
cp /run/bao-auth/role_id   /tmp/bao-rw/role_id
cp /run/bao-auth/secret_id /tmp/bao-rw/secret_id
cp /run/bao-auth/agent.hcl /tmp/bao-rw/agent.hcl
busybox chown nobody:nobody /tmp/bao-rw/role_id /tmp/bao-rw/secret_id
chmod 600 /tmp/bao-rw/role_id /tmp/bao-rw/secret_id

log "start bao agent (proxy on 127.0.0.1:8100)"
/usr/local/bin/bao agent -config=/tmp/bao-rw/agent.hcl > /tmp/bao-agent.log 2>&1 &

log "wait for agent authenticated"
i=0
until busybox wget -qO- "${BAO_PROXY}/v1/auth/token/lookup-self" > /dev/null 2>&1; do
  i=$((i+1))
  [ $i -lt 60 ] || { log "agent auth timed out"; busybox cat /tmp/bao-agent.log >&2; exit 1; }
  busybox sleep 1
done
log "agent ready + authenticated"

fetch() {
  busybox wget -qO- "${BAO_PROXY}/v1/secret/data/$1" \
    | sed -n 's/.*"value":"\([^"]*\)".*/\1/p'
}

log "fetch agent secrets ($ZEROCLAW_AGENT_PATH)"
DISCORD_TOKEN_VALUE=$(fetch "${ZEROCLAW_AGENT_PATH}/discord-bot-token")
OPENROUTER_API_KEY=$(fetch "${ZEROCLAW_AGENT_PATH}/openrouter-key")

log "fetch shared + tool-infra"
PLANE_API_KEY=$(fetch shared/plane-api-key)
BROWSER_USE_API_KEY=$(fetch tool-infra/browser-use-api-key)
SUPABASE_URL=$(fetch tool-infra/supabase-url)
SUPABASE_SERVICE_KEY=$(fetch tool-infra/supabase-service-key)
SUPABASE_ANON_KEY=$(fetch tool-infra/supabase-anon-key)
SUPABASE_PROJECT_ID=$(fetch tool-infra/supabase-project-id)
GOOGLE_ADS_CLIENT_ID=$(fetch tool-infra/google-ads-client-id)
GOOGLE_ADS_CLIENT_SECRET=$(fetch tool-infra/google-ads-client-secret)
GOOGLE_ADS_REFRESH_TOKEN=$(fetch tool-infra/google-ads-refresh-token)
GOOGLE_ADS_DEVELOPER_TOKEN=$(fetch tool-infra/google-ads-developer-token)
GOOGLE_ADS_LOGIN_CUSTOMER_ID=$(fetch tool-infra/google-ads-login-customer-id)

for v in DISCORD_TOKEN_VALUE PLANE_API_KEY OPENROUTER_API_KEY BROWSER_USE_API_KEY \
         SUPABASE_URL SUPABASE_SERVICE_KEY SUPABASE_ANON_KEY SUPABASE_PROJECT_ID \
         GOOGLE_ADS_CLIENT_ID GOOGLE_ADS_CLIENT_SECRET GOOGLE_ADS_REFRESH_TOKEN \
         GOOGLE_ADS_DEVELOPER_TOKEN GOOGLE_ADS_LOGIN_CUSTOMER_ID; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { log "empty: $v"; exit 1; }
done
log "all 13 env vars populated"

export PLANE_API_KEY OPENROUTER_API_KEY BROWSER_USE_API_KEY \
       SUPABASE_URL SUPABASE_SERVICE_KEY SUPABASE_ANON_KEY SUPABASE_PROJECT_ID \
       GOOGLE_ADS_CLIENT_ID GOOGLE_ADS_CLIENT_SECRET GOOGLE_ADS_REFRESH_TOKEN \
       GOOGLE_ADS_DEVELOPER_TOKEN GOOGLE_ADS_LOGIN_CUSTOMER_ID
export OPENAI_API_KEY="$OPENROUTER_API_KEY"   # OpenRouter is OpenAI-API-compatible
export API_KEY="$OPENROUTER_API_KEY"
export BAO_PROXY_ADDR="$BAO_PROXY"

log "stage tmpfs config at $TMP_DIR"
cp "$PERSIST_DIR/config.toml" "$TMP_DIR/config.toml"
chmod 600 "$TMP_DIR/config.toml"

# Inject Discord bot token into config.toml (kept out of env vars)
esc=$(printf "%s" "$DISCORD_TOKEN_VALUE" | sed "s/[\\&/]/\\\\&/g")
sed -i "s@^bot_token = \".*\"@bot_token = \"$esc\"@" "$TMP_DIR/config.toml"
grep -q "^bot_token = \"$esc\"" "$TMP_DIR/config.toml" || { log "bot_token rewrite failed"; exit 1; }
unset DISCORD_TOKEN_VALUE esc

log "symlink runtime files"
for f in brain.db daemon_state.json .secret_key otp-secret; do
  [ -e "$PERSIST_DIR/$f" ] && ln -sf "$PERSIST_DIR/$f" "$TMP_DIR/$f"
done

log "exec zeroclaw daemon --config-dir $TMP_DIR"
exec zeroclaw daemon --config-dir "$TMP_DIR"
