#!/bin/bash
# OpenBao Agent entrypoint for Hermes — a bash/Ubuntu AI agent.
# This is the production entrypoint used by ARC's Hermes agent.
#
# Hermes is a multi-platform AI gateway (Discord, Slack, etc.) running on
# Ubuntu inside Docker. It uses curl + python3 for secret fetching.
#
# Secrets fetched at startup:
#   hermes/discord-bot-token
#   hermes/openrouter-key
#   shared/plane-api-key
#   tool-infra/{supabase-url, supabase-service-key, supabase-anon-key, supabase-project-id}
#   tool-infra/browser-use-api-key
#   tool-infra/{google-ads-client-id, google-ads-client-secret, google-ads-refresh-token,
#               google-ads-developer-token, google-ads-login-customer-id}
set -eu

BAO_PROXY="http://127.0.0.1:8100"

log() { printf "[openbao-hermes] %s\n" "$*" >&2; }

log "stage AppRole creds (root-owned 600 in /tmp)"
mkdir -p /tmp/bao-rw
cp /run/bao-auth/role_id   /tmp/bao-rw/role_id
cp /run/bao-auth/secret_id /tmp/bao-rw/secret_id
cp /run/bao-auth/agent.hcl /tmp/bao-rw/agent.hcl
chmod 600 /tmp/bao-rw/role_id /tmp/bao-rw/secret_id

log "start bao agent (proxy on 127.0.0.1:8100)"
/usr/local/bin/bao agent -config=/tmp/bao-rw/agent.hcl > /tmp/bao-agent.log 2>&1 &

log "wait for agent authenticated"
i=0
until python3 -c "import urllib.request; urllib.request.urlopen('${BAO_PROXY}/v1/auth/token/lookup-self', timeout=2)" > /dev/null 2>&1; do
  i=$((i+1))
  [ $i -lt 60 ] || { log "agent auth timed out"; cat /tmp/bao-agent.log >&2; exit 1; }
  sleep 1
done
log "agent ready + authenticated"

fetch() {
  TOKEN="$BAO_PROXY" P="$1" python3 << 'PY'
import os, urllib.request, json, sys
addr = os.environ["TOKEN"]
req = urllib.request.Request(addr + "/v1/secret/data/" + os.environ["P"].lstrip("/"))
try:
    r = json.loads(urllib.request.urlopen(req, timeout=15).read())
    print(r["data"]["data"]["value"])
except Exception as e:
    print(f"ERR:{e}", file=sys.stderr)
    sys.exit(2)
PY
}

log "fetch hermes + shared"
PLANE_API_KEY=$(fetch shared/plane-api-key)
DISCORD_BOT_TOKEN=$(fetch hermes/discord-bot-token)
OPENROUTER_API_KEY=$(fetch hermes/openrouter-key)

log "fetch tool-infra"
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

for v in PLANE_API_KEY DISCORD_BOT_TOKEN OPENROUTER_API_KEY \
         BROWSER_USE_API_KEY SUPABASE_URL SUPABASE_SERVICE_KEY \
         SUPABASE_ANON_KEY SUPABASE_PROJECT_ID \
         GOOGLE_ADS_CLIENT_ID GOOGLE_ADS_CLIENT_SECRET \
         GOOGLE_ADS_REFRESH_TOKEN GOOGLE_ADS_DEVELOPER_TOKEN \
         GOOGLE_ADS_LOGIN_CUSTOMER_ID; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { log "empty: $v"; exit 1; }
done
log "all 13 env vars populated"

export PLANE_API_KEY DISCORD_BOT_TOKEN OPENROUTER_API_KEY \
       BROWSER_USE_API_KEY SUPABASE_URL SUPABASE_SERVICE_KEY \
       SUPABASE_ANON_KEY SUPABASE_PROJECT_ID \
       GOOGLE_ADS_CLIENT_ID GOOGLE_ADS_CLIENT_SECRET \
       GOOGLE_ADS_REFRESH_TOKEN GOOGLE_ADS_DEVELOPER_TOKEN \
       GOOGLE_ADS_LOGIN_CUSTOMER_ID
export BAO_PROXY_ADDR="$BAO_PROXY"

log "exec hermes gateway"
exec /opt/hermes/docker/entrypoint.sh gateway run
