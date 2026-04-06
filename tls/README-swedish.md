# tls/

Plats för Nomad mTLS-certifikat. Inga certifikat eller nycklar får checkas in i Git —
`.gitignore` blockerar alla filer utom denna README.

## Vad ska ligga här (på servern)

Genereras automatiskt av `nomad-setup.sh --server`:

```
nomad-agent-ca.pem          CA-certifikat
nomad-agent-ca-key.pem      CA-nyckel (stanna på servern)
global-server-nomad.pem     Servercertifikat
global-server-nomad-key.pem Servernyckel
global-client-nomad.pem     Klientcertifikat (kopieras till workers)
global-client-nomad-key.pem Klientnyckel     (kopieras till workers)
global-cli-nomad.pem        CLI-certifikat   (används lokalt på servern)
global-cli-nomad-key.pem    CLI-nyckel       (används lokalt på servern)
```

Certifikaten lagras av skriptet i `/etc/nomad.d/tls/` — denna mapp är bara
en tillfällig mellanlagringsplats om du behöver flytta filer manuellt.

## Vad ska ligga här (på varje worker)

Tre filer kopieras från servern innan `nomad-setup.sh --worker` körs:

```
nomad-agent-ca.pem          CA-certifikat (samma för hela klustret)
global-client-nomad.pem     Klientcertifikat
global-client-nomad-key.pem Klientnyckel
```

Exempel med scp från servern:

```bash
scp server:/etc/nomad.d/tls/nomad-agent-ca.pem          tls/
scp server:/etc/nomad.d/tls/global-client-nomad.pem     tls/
scp server:/etc/nomad.d/tls/global-client-nomad-key.pem tls/
```

Kör sedan:

```bash
./nomad-setup.sh --worker --server-ip <IP> --tls-dir tls/
```

## Påminnelse

| Fil              | Får lämna servern | Får checkas in |
|------------------|:-----------------:|:--------------:|
| `*-ca.pem`       | Ja                | **Nej**        |
| `*-ca-key.pem`   | **Nej**           | **Nej**        |
| `*-cert.pem`     | Ja                | **Nej**        |
| `*-key.pem`      | **Nej**           | **Nej**        |
