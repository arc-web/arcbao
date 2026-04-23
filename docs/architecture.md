# Architecture

## The core problem

When an AI agent container starts, its entrypoint typically authenticates to a secrets manager, fetches credentials, and exports them as environment variables. This works — but only for boot time.

The AppRole pattern in OpenBao (and Vault) is specifically designed to be one-shot: the `secret_id` is consumed on first use and cannot be reused. After the entrypoint finishes, the authentication material is gone. The token it got is also typically short-lived.

This creates a problem for long-running AI agent sessions: if the agent needs a secret that wasn't loaded at boot — a new API key, a credential added after startup, or something the agent needs to look up dynamically — there's no way to get it. The agent has no token, no AppRole creds, and no path back to the vault.

## The sidecar proxy solution

The fix is to keep an OpenBao Agent process running inside the container as a sidecar throughout the container's lifetime.

**What bao agent does:**
1. Reads `role_id` and `secret_id` from files at startup
2. Performs AppRole authentication against the OpenBao server
3. Gets a token and writes it to a sink file (optional — the proxy uses it internally)
4. Starts an HTTP listener on `127.0.0.1:8100`
5. Proxies all incoming requests to the OpenBao server, injecting the token automatically
6. Renews the token before it expires; re-authenticates if the token hits max TTL

**What the entrypoint and agent process get:**
- A local HTTP endpoint at `http://127.0.0.1:8100` that behaves exactly like the OpenBao API
- No auth header needed — the proxy handles it
- The full KV-v2 API, so any secret can be fetched at any point during the session

## Startup sequence

```
1. Container starts
2. Entrypoint copies AppRole creds from /run/bao-auth/ to /tmp/bao-rw/
   (working copy — agent reads from here)
3. bao agent starts in background, reads creds, authenticates
4. Entrypoint polls http://127.0.0.1:8100/v1/auth/token/lookup-self
   until agent is authenticated (up to 60s)
5. Entrypoint fetches startup secrets through the proxy:
   GET http://127.0.0.1:8100/v1/secret/data/{path}
   Response: {"data": {"data": {"value": "..."}}}
6. Startup secrets exported as environment variables
7. Main agent process starts, inherits env vars
8. bao agent continues running in background
9. Agent process can fetch any secret at any time via http://127.0.0.1:8100
```

## Credential file layout

AppRole credentials live on the host under `/etc/openbao/{agent-name}/` and are mounted read-only into the container:

```
Host:
  /etc/openbao/my-agent/
    role_id      (contains the AppRole role UUID)
    secret_id    (contains the AppRole secret UUID, chmod 600)
    agent.hcl    (OpenBao Agent config pointing to /tmp/bao-rw/)

Container mount:
  /run/bao-auth/role_id     (ro bind mount from host)
  /run/bao-auth/secret_id   (ro bind mount from host)
  /run/bao-auth/agent.hcl   (ro bind mount from host)

Entrypoint copies to writable tmpfs:
  /tmp/bao-rw/role_id
  /tmp/bao-rw/secret_id
  /tmp/bao-rw/agent.hcl
  (bao agent reads from here)
```

The copy-to-tmpfs step exists because `bao agent` needs write access to the directory containing its config (to write a token sink). Since `/run/bao-auth/` is read-only, the entrypoint stages a writable copy.

## Security properties

- **No AppRole creds in environment**: `BAO_ROLE_ID` and `BAO_SECRET_ID` never appear as env vars in the container. They're in files, read by the agent process, and not accessible to the main agent process.
- **No token in environment**: the token lives inside the bao agent process and its sink file, not in any environment variable.
- **Secrets in memory only**: startup secrets are fetched into shell variables and exported. They're never written to disk inside the container.
- **Least privilege**: each agent has its own AppRole with a policy restricting it to its own secret paths. Hermes cannot read ZeroClaw's secrets.
- **Auto-renewal**: the agent process handles token renewal automatically. If a session runs longer than the token TTL, the agent re-authenticates silently.
- **Host isolation**: AppRole credentials on the host (`/etc/openbao/`) are root-owned, 600. Only the Docker daemon (root) can read them to bind-mount them.

## Per-agent isolation

Each agent has:
- Its own AppRole role (different `role_id` + `secret_id`)
- Its own policy (restricts reads to that agent's paths only)
- Its own credential directory on the host

Example policy structure:
```
hermes:       reads secret/data/hermes/*, secret/data/shared/*, secret/data/tool-infra/*
zeroclaw-alpha: reads secret/data/zeroclaw-alpha/*, secret/data/shared/*, secret/data/tool-infra/*
zeroclaw-bravo: reads secret/data/zeroclaw-bravo/*, secret/data/shared/*, secret/data/tool-infra/*
```

Agents cannot cross-read each other's secrets even if they know the path.

## Container base compatibility

| Base | Fetch command | JSON parsing |
|------|--------------|--------------|
| Ubuntu/Debian (bash) | `curl -s http://127.0.0.1:8100/v1/secret/data/{path}` | `python3 -c "import sys,json; print(json.load(sys.stdin)['data']['data']['value'])"` |
| Alpine/busybox (sh) | `busybox wget -qO- http://127.0.0.1:8100/v1/secret/data/{path}` | `busybox sed -n 's/.*"value":"\([^"]*\)".*/\1/p'` |

The `bao` binary itself is a statically linked Go binary. It runs in either environment. Mount it from the host rather than baking it into the image — this keeps images lean and lets you update the binary without rebuilding.
