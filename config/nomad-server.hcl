server {
  enabled          = true
  bootstrap_expect = 1
}

data_dir = "/opt/nomad"

advertise {
  http = "0.0.0.0:4646"
  rpc  = "0.0.0.0:4647"
  serf = "0.0.0.0:4648"
}

tls {
  http = true
  rpc  = true

  ca_file   = "/etc/nomad.d/tls/nomad-agent-ca.pem"
  cert_file = "/etc/nomad.d/tls/global-server-nomad.pem"
  key_file  = "/etc/nomad.d/tls/global-server-nomad-key.pem"

  verify_server_hostname = true
  verify_https_client    = true
}
