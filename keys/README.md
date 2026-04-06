# keys/

Directory for SSH public keys. Each team member places their public key here
so that `ssh-setup.sh` can automatically add it to `authorized_keys` on every
node.

## Adding your key

```bash
# Copy your existing public key
cp ~/.ssh/id_ed25519.pub keys/your-name.pub

# Or generate a new ed25519 key pair first
ssh-keygen -t ed25519 -C "your@email.com"
cp ~/.ssh/id_ed25519.pub keys/your-name.pub

# Commit it
git add keys/your-name.pub
git commit -m "Add your-name SSH public key"
git push
```

Then re-run `ssh-setup.sh` on any node to pick up the new key:

```bash
./ssh-setup.sh
```

## Is it safe to commit public keys here?

Yes. A public key is designed to be shared freely — that is its purpose.
Only the private key (`~/.ssh/id_ed25519`, without the `.pub` extension)
must be kept secret and must never be committed anywhere.

## Key format

Only ed25519 keys are recommended. The file should contain a single line:

```
ssh-ed25519 AAAA... comment
```

RSA keys will work but are discouraged — see `ssh-setup.sh --help` for details.

## What .gitignore allows

Only `.pub` files and this README may be committed. All other files
(private keys, certificates, config files) are blocked.
