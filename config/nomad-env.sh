# Source this file to use the Nomad CLI with mTLS enabled:
#   source /etc/nomad.d/nomad-env.sh
#
# Or add it to ~/.bashrc / ~/.profile for permanent effect.

export NOMAD_ADDR=https://127.0.0.1:4646
export NOMAD_CACERT=/etc/nomad.d/tls/nomad-agent-ca.pem
export NOMAD_CLIENT_CERT=/etc/nomad.d/tls/global-cli-nomad.pem
export NOMAD_CLIENT_KEY=/etc/nomad.d/tls/global-cli-nomad-key.pem
