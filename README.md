# nomad-worker-setup
Hashicorp Nomad setup for worker and server

Requires:
- OpenSUSE: Leap, Slowroll or Tumbleweed
- Running either on physical hardware or WSL2

First setup the server with:
- ./nomad-setup.sh --server
- Note the IP address of the server or the hostname.

Then setup the worker with any of the following:
- ./nomad-setup.sh --worker --server-ip <server-ip>
- ./nomad-setup.sh --worker --server-host <server-host>

