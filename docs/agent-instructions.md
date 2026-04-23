# Documenting the Vault Proxy for AI Agents

## Why this matters

Once the sidecar proxy is running and the entrypoint has fetched startup secrets, everything works at the infrastructure level. But there's a second layer: the AI agent itself needs to know the proxy exists.

AI agents read instruction files (system prompts, AGENTS.md files, skill definitions) to understand what tools and capabilities they have. If the vault proxy isn't documented there, the agent doesn't know it can fetch secrets mid-session. It may try to re-authenticate with AppRole credentials that are already consumed, report that it has no access, or simply not attempt to fetch secrets at all.

The fix is adding a short block to whatever instruction file your agent reads at startup.

## Template block

Add this to your agent's instruction file (AGENTS.md, system prompt, or equivalent). Customize the known paths section for your agent's actual allowed paths.

```markdown
## OpenBao Vault Proxy (Live Secret Fetches)

An OpenBao Agent proxy runs at http://127.0.0.1:8100 inside this container.
No authentication header is needed - the agent injects the token automatically.

To fetch a secret at any point during a session:

**bash/Ubuntu containers:**
curl -s http://127.0.0.1:8100/v1/secret/data/{path} \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['data']['value'])"

**busybox/Alpine containers:**
busybox wget -qO- http://127.0.0.1:8100/v1/secret/data/{path} \
  | busybox sed -n 's/.*"value":"\([^"]*\)".*/\1/p'

Environment variable BAO_PROXY_ADDR is set to http://127.0.0.1:8100.

Known secret paths this agent can read:
- my-agent/api-key
- my-agent/discord-token
- shared/plane-api-key
- tool-infra/supabase-url
- tool-infra/supabase-service-key
(list all paths your AppRole policy allows)

Note: Do NOT attempt to authenticate with BAO_ROLE_ID or BAO_SECRET_ID.
Those credentials were consumed at startup by the agent process. Use the
proxy at http://127.0.0.1:8100 instead.
```

## What to include

**Required:**
- The proxy address (`http://127.0.0.1:8100`)
- The fetch command for your container's available tools (curl vs wget, python3 vs sed)
- Explicit note that no auth header is needed
- The list of secret paths the agent is allowed to read

**Recommended:**
- `BAO_PROXY_ADDR` env var mention (so the agent can verify the proxy is configured)
- Explicit warning not to attempt AppRole re-authentication (prevents wasted turns)

**Exclude:**
- The AppRole role_id or secret_id (not needed at runtime, agent can't use them anyway)
- The vault server address (agent talks to the local proxy, not the server directly)

## Placement

Put this block near the top of your instruction file, before tool listings or other capabilities. Agents scan instruction files top-down and should encounter this before attempting any secret fetch.

If your agent has a tiered capability model ("always available" vs "requires approval"), the vault proxy fetch belongs in the "always available" tier — it requires no external calls, no approval, and no network access beyond localhost.

## Verification prompt

After updating your agent's instructions and restarting, test with:

```
Fetch [some secret path] live from the vault proxy. 
Run the command and show me the first 6 characters of the value.
```

A passing agent will run the fetch command and return the truncated value. A failing agent will say it doesn't have OpenBao credentials or attempt AppRole authentication.

## Common failure mode

Agent says: "I can't access OpenBao — the AppRole credentials were consumed at startup."

This means the agent has not been told about the proxy. It knows AppRole auth happened but doesn't know the proxy is still running. Add the template block above and restart.
