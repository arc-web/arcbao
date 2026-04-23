# Setup Guide

## Prerequisites

- OpenBao server running and unsealed (or HashiCorp Vault — API is compatible)
- `bao` CLI installed on the host machine
- Docker on the host
- Root/sudo access on the host for writing to `/etc/openbao/`

## 1. Install OpenBao

```bash
# Download bao binary (check https://github.com/openbao/openbao/releases for latest)
curl -LO https://github.com/openbao/openbao/releases/download/v2.x.x/bao_linux_amd64
chmod +x bao_linux_amd64
mv bao_linux_amd64 /usr/local/bin/bao

# Or run OpenBao in Docker
docker run -d --name openbao \
  -p 8200:8200 \
  -e VAULT_DEV_ROOT_TOKEN_ID=root \
  openbao/openbao:latest server -dev
```

Set your environment:
```bash
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=root   # dev mode only
```

For production, unseal OpenBao properly and use a non-root token.

## 2. Enable KV-v2 secret engine

```bash
bao secrets enable -path=secret kv-v2
```

If already enabled, skip this step.

## 3. Write your secrets

```bash
# Agent-specific secrets
bao kv put secret/my-agent/api-key value="sk-..."
bao kv put secret/my-agent/discord-token value="..."

# Shared secrets (readable by multiple agents)
bao kv put secret/shared/plane-api-key value="..."

# Infra/tool secrets
bao kv put secret/tool-infra/supabase-url value="https://..."
bao kv put secret/tool-infra/supabase-service-key value="..."
```

The `value` field convention is used throughout this pattern. All secrets are stored as a single `value` field inside the KV entry. Adjust to your naming convention if needed.

## 4. Create a policy for the agent

Save this as `my-agent-policy.hcl` (or use [templates/policy-example.hcl](../templates/policy-example.hcl)):

```hcl
path "secret/data/my-agent/*" {
  capabilities = ["read"]
}

path "secret/data/shared/*" {
  capabilities = ["read"]
}

path "secret/data/tool-infra/*" {
  capabilities = ["read"]
}
```

Write it:
```bash
bao policy write my-agent my-agent-policy.hcl
```

Each agent should have its own policy. Never give an agent a wildcard policy (`secret/data/*`) — restrict it to paths it actually needs.

## 5. Enable AppRole auth and create a role

```bash
# Enable AppRole (one time)
bao auth enable approle

# Create a role for this agent
bao write auth/approle/role/my-agent \
    token_policies="my-agent" \
    token_ttl=1h \
    token_max_ttl=24h \
    secret_id_ttl=0        # 0 = never expires (use a positive duration for rotation)
```

`token_ttl` is how long each token lives before the agent renews it. `token_max_ttl` is the absolute ceiling — after this the agent re-authenticates using the `secret_id`.

## 6. Get role_id and secret_id

```bash
# Get role_id (not sensitive — but don't commit it)
bao read auth/approle/role/my-agent/role-id

# Generate a secret_id (treat like a password)
bao write -f auth/approle/role/my-agent/secret-id
```

Save both values. You will write them to files on the host.

## 7. Write credential files to the host

```bash
AGENT=my-agent

sudo mkdir -p /etc/openbao/$AGENT
echo "<role-id-value>"   | sudo tee /etc/openbao/$AGENT/role_id > /dev/null
echo "<secret-id-value>" | sudo tee /etc/openbao/$AGENT/secret_id > /dev/null
sudo cp /path/to/arcbao/templates/agent.hcl /etc/openbao/$AGENT/agent.hcl

# Restrict access
sudo chmod 600 /etc/openbao/$AGENT/role_id /etc/openbao/$AGENT/secret_id
sudo chmod 644 /etc/openbao/$AGENT/agent.hcl
```

Edit `/etc/openbao/$AGENT/agent.hcl` and set `vault.address` to your OpenBao server address.

## 8. Update your docker-compose file

Add to your service definition (see [templates/docker-compose.yml](../templates/docker-compose.yml) for full example):

```yaml
volumes:
  - /usr/local/bin/bao:/usr/local/bin/bao:ro
  - /etc/openbao/my-agent/role_id:/run/bao-auth/role_id:ro
  - /etc/openbao/my-agent/secret_id:/run/bao-auth/secret_id:ro
  - /etc/openbao/my-agent/agent.hcl:/run/bao-auth/agent.hcl:ro
```

Do not pass `BAO_ROLE_ID` or `BAO_SECRET_ID` as environment variables. The file-mount pattern keeps credentials off the environment.

## 9. Use the entrypoint template

Copy the appropriate template and customize:

- **bash/Ubuntu**: [templates/entrypoint-bash.sh](../templates/entrypoint-bash.sh)
- **sh/busybox/Alpine**: [templates/entrypoint-busybox.sh](../templates/entrypoint-busybox.sh)

Customize the secret fetch section at the bottom to pull the secrets your agent needs at startup.

## 10. Verify

After deploying, from inside the container:

```bash
# Check proxy is up
printenv BAO_PROXY_ADDR

# Fetch a secret
curl -s http://127.0.0.1:8100/v1/secret/data/my-agent/api-key \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['data']['value'][:6])"
```

You should see the first 6 characters of your secret value. If the proxy isn't up, check the bao agent logs:
```bash
cat /tmp/bao-agent.log
```

## Multiple agents

Repeat steps 4-9 for each agent. Each gets:
- Its own policy (different allowed paths)
- Its own AppRole role + credentials
- Its own directory under `/etc/openbao/`
- The same entrypoint template with different secret paths

The bao binary is shared (same bind mount). The credential files are per-agent.

## Credential rotation

To rotate a `secret_id`:

```bash
# Generate a new one
bao write -f auth/approle/role/my-agent/secret-id

# Write it to the host file
echo "<new-secret-id>" | sudo tee /etc/openbao/my-agent/secret_id > /dev/null

# Restart the container — the agent will pick up the new secret_id at startup
docker restart my-agent
```

The old `secret_id` is invalidated automatically when the new one is generated (if you configured `secret_id_num_uses=1`). For continuous operation, use `secret_id_num_uses=0` (unlimited uses) and rotate on a schedule.
