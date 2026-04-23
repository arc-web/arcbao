# arcbao

OpenBao Agent sidecar proxy pattern for AI agent containers. Gives every agent container live, authenticated access to secrets at any point during a session — not just at boot.

## The problem

AI agents run inside containers. When they start, an entrypoint script authenticates to OpenBao with AppRole credentials, fetches secrets, and exports them as environment variables. That works fine for startup. But AppRole credentials are one-shot: once the entrypoint consumes the `secret_id`, it's gone. If the agent needs a new secret mid-session — a new API key, rotating credentials, a secret the operator just added — there's no way to get it. The token is gone, the creds are gone, and the agent is stuck with whatever it had at boot.

## The solution

Run an OpenBao Agent process inside the container as a sidecar. The agent:

- Reads the AppRole credentials at startup
- Authenticates to OpenBao and gets a token
- Starts a local HTTP proxy on `127.0.0.1:8100`
- Auto-renews the token until max TTL, then re-authenticates

The entrypoint and the agent process both fetch secrets by hitting `http://127.0.0.1:8100/v1/secret/data/{path}`. No auth header needed — the proxy injects the token automatically. No credentials in environment variables. No secrets on disk after startup.

```
┌─────────────────────────────────────────────────────────────────┐
│  Container                                                      │
│                                                                 │
│  ┌─────────────────┐    HTTP (no auth)    ┌─────────────────┐  │
│  │   Agent Process  │ ─────────────────►  │   bao agent     │  │
│  │   (your AI app) │                      │   proxy :8100   │  │
│  └─────────────────┘                      └────────┬────────┘  │
│                                                     │           │
│  ┌─────────────────┐    HTTP (no auth)              │ (token    │
│  │   Entrypoint    │ ─────────────────►  (same)     │  injected │
│  │   (boot script) │                                │  by agent)│
│  └─────────────────┘                                │           │
└────────────────────────────────────────────────────┼───────────┘
                                                      │ HTTPS + token
                                                      ▼
                                             ┌─────────────────┐
                                             │    OpenBao      │
                                             │    Server       │
                                             └─────────────────┘
```

## Quick start

**1. Set up OpenBao AppRole for your agent** (see [docs/setup.md](docs/setup.md)):
```bash
bao auth enable approle
bao policy write my-agent policy-example.hcl
bao write auth/approle/role/my-agent token_policies="my-agent"
bao read auth/approle/role/my-agent/role-id    # save this
bao write -f auth/approle/role/my-agent/secret-id  # save this
```

**2. Write credential files to the host**:
```bash
mkdir -p /etc/openbao/my-agent
echo "<role-id>"   > /etc/openbao/my-agent/role_id
echo "<secret-id>" > /etc/openbao/my-agent/secret_id
cp templates/agent.hcl /etc/openbao/my-agent/agent.hcl
chmod 600 /etc/openbao/my-agent/role_id /etc/openbao/my-agent/secret_id
```

**3. Add volume mounts to your compose file** (see [templates/docker-compose.yml](templates/docker-compose.yml)):
```yaml
volumes:
  - /usr/local/bin/bao:/usr/local/bin/bao:ro
  - /etc/openbao/my-agent/role_id:/run/bao-auth/role_id:ro
  - /etc/openbao/my-agent/secret_id:/run/bao-auth/secret_id:ro
  - /etc/openbao/my-agent/agent.hcl:/run/bao-auth/agent.hcl:ro
```

**4. Use the entrypoint template** for your container base:
- Ubuntu/Debian (bash + python3): [templates/entrypoint-bash.sh](templates/entrypoint-bash.sh)
- Alpine/busybox: [templates/entrypoint-busybox.sh](templates/entrypoint-busybox.sh)

## Fetching secrets at runtime

From inside the container, at any point during a session:

```bash
# bash + curl + python3
curl -s http://127.0.0.1:8100/v1/secret/data/myapp/api-key \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['data']['value'])"

# busybox only (Alpine)
busybox wget -qO- http://127.0.0.1:8100/v1/secret/data/myapp/api-key \
  | busybox sed -n 's/.*"value":"\([^"]*\)".*/\1/p'

# printenv to verify proxy is up
printenv BAO_PROXY_ADDR  # http://127.0.0.1:8100
```

## Telling your AI agent about it

If your container runs an AI agent, document the proxy in the agent's instruction file. See [docs/agent-instructions.md](docs/agent-instructions.md) for the template block.

Without this, a working proxy is invisible to the AI — it'll try to re-authenticate with AppRole credentials that no longer exist, or report it has no way to fetch secrets.

## Tested with

- **Hermes** (bash/Ubuntu) — passed live fetch of `plane-api-key`, `openrouter-key` via curl + python3
- **ZeroClaw Alpha + Bravo** (sh/busybox/Alpine) — same pattern with busybox wget + sed

## Contents

```
templates/          Ready-to-use templates (genericized, no org-specific values)
examples/hermes/    Reference implementation: bash/Ubuntu AI agent
examples/zeroclaw/  Reference implementation: busybox/Alpine AI agent
docs/               Architecture, setup guide, agent instruction pattern
```

## Requirements

- OpenBao (or HashiCorp Vault — the API is compatible)
- `bao` binary on the host, bind-mounted into containers
- AppRole auth method enabled on the vault server
- KV-v2 secret engine mounted at `secret/`
