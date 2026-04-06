server {
  enabled = true
  bootstrap_expect = 1
}

data_dir = "/opt/nomad"

advertise {
  http = "0.0.0.0:4646"
  rpc  = "0.0.0.0:4647"
  serf = "0.0.0.0:4648"
}
