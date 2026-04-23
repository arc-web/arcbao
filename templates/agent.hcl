# OpenBao Agent config for sidecar proxy pattern.
#
# Mount this file at /run/bao-auth/agent.hcl (read-only).
# The entrypoint copies it to /tmp/bao-rw/agent.hcl before starting the agent.
#
# Set vault.address to your OpenBao server address.
# Everything else can be left as-is.

vault {
  address = "http://openbao:8200"   # Change to your OpenBao server address
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                    = "/tmp/bao-rw/role_id"
      secret_id_file_path                  = "/tmp/bao-rw/secret_id"
      remove_secret_id_file_after_reading  = false
    }
  }

  sink "file" {
    config = {
      path = "/tmp/bao-rw/token"
    }
  }
}

api_proxy {
  use_auto_auth_token = true
}

listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}

cache {}
