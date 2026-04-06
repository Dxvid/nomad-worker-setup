client {
  enabled = true
  servers = ["${SERVER_ADDR}:4647"]

  meta {
    cpu_model = "${CPU_MODEL}"
    cpu_cores = "${CPU_CORES}"
    ram_gb    = "${RAM_GB}"
    gpu_model = "${GPU_MODEL}"
    wsl2      = "${IS_WSL2}"
  }
}

data_dir = "/opt/nomad"

tls {
  http = true
  rpc  = true

  ca_file   = "/etc/nomad.d/tls/nomad-agent-ca.pem"
  cert_file = "/etc/nomad.d/tls/global-client-nomad.pem"
  key_file  = "/etc/nomad.d/tls/global-client-nomad-key.pem"

  verify_server_hostname = true
  verify_https_client    = true
}
