# Example OpenBao policy for an AI agent.
#
# This policy restricts the agent to reading only its own secrets,
# shared secrets, and shared tool-infra secrets.
#
# Apply with:
#   bao policy write my-agent policy-example.hcl

# Agent-specific secrets (only this agent can read these)
path "secret/data/my-agent/*" {
  capabilities = ["read"]
}

# Shared secrets readable by all agents
path "secret/data/shared/*" {
  capabilities = ["read"]
}

# Shared tool/infrastructure secrets
path "secret/data/tool-infra/*" {
  capabilities = ["read"]
}
