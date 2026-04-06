# tls/

Staging directory for Nomad mTLS certificates. No certificates or keys may be
committed to Git — `.gitignore` blocks all files except this README.

## Server — files generated here

Generated automatically by `nomad-setup.sh --server` and stored in `/etc/nomad.d/tls/`.
Use this directory as a temporary staging area when moving files manually.

```
nomad-agent-ca.pem            CA certificate (shared across the cluster)
nomad-agent-ca-key.pem        CA private key  — NEVER leave the server
global-server-nomad.pem       Server certificate
global-server-nomad-key.pem   Server private key
global-client-nomad.pem       Client certificate (copy to each worker)
global-client-nomad-key.pem   Client private key  (copy to each worker)
global-cli-nomad.pem          CLI certificate (used locally on the server)
global-cli-nomad-key.pem      CLI private key
```

## Worker — files to copy from the server

Copy three files from the server before running `nomad-setup.sh --worker`:

```bash
scp server:/etc/nomad.d/tls/nomad-agent-ca.pem          tls/
scp server:/etc/nomad.d/tls/global-client-nomad.pem     tls/
scp server:/etc/nomad.d/tls/global-client-nomad-key.pem tls/
```

Then run:

```bash
./nomad-setup.sh --worker --server-ip <IP> --tls-dir tls/
```

## Security reference

| File                | May leave server | May be committed |
|---------------------|:----------------:|:----------------:|
| `*-ca.pem`          | Yes              | **No**           |
| `*-ca-key.pem`      | **No**           | **No**           |
| `*-nomad.pem`       | Yes              | **No**           |
| `*-nomad-key.pem`   | **No**           | **No**           |
