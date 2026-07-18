# rustdesk-repo

Self-updating package repository serving RustDesk preconfigured for the
Blacklog server (`help.blacklog.net`), hosted at https://pkgs.blacklog.net.

## How it works

A daily GitHub Actions run (`.github/workflows/build.yml`):

1. Fetches the latest official RustDesk release.
2. Mirrors the Linux packages (`.deb`, `.rpm`, `.pkg.tar.zst` when upstream
   ships one) unchanged.
3. Builds `rustdesk-blacklog-config` — a small companion package for each
   format whose post-install points the RustDesk service at the Blacklog
   server (`--option custom-rendezvous-server / relay-server / key`).
4. Generates signed **apt**, **dnf** and **pacman** repo trees.
5. Prepares Windows/macOS downloads: the official Windows installer renamed
   with filename-embedded config (`rustdesk-host=…,key=….exe` — RustDesk
   reads its own filename on first run), a silent-deploy `install.ps1`, the
   macOS dmgs and a one-shot configure script.
6. Ships everything in an nginx image → `ghcr.io/reventlow/rustdesk-repo:latest`.

Watchtower on zima auto-deploys the new image; clients then update through
their normal package manager (`apt upgrade` / `dnf upgrade` / `pacman -Syu`).

## Secrets

- `GPG_PRIVATE_KEY` — armored private key signing the apt Release and rpm
  repomd. Public half is served at `/blacklog-repo.key`. Keep an offline
  copy; rotating it means clients re-import the key.

## Client setup

See the landing page at https://pkgs.blacklog.net (generated from
`web/index.html.tmpl`) for per-distro one-liners.

## Admin (technician) client

`admin/` holds the pre-built branded custom clients (`gorm-help`) generated
from the RustDesk Pro console — Debian, Fedora and Arch. They embed the
server address, api-server (console login) and the public key; no access
password. The build script folds them into the apt/dnf/pacman repos so
admin machines can install them:

```
sudo apt install gorm-help        # or dnf / pacman
```

They are intentionally **not** linked from the landing page or blacklog.net —
present in the repo index but unadvertised. Note the repos are public and
unauthenticated, so the packages are discoverable by anyone who lists the
index; there is nothing secret in them beyond the (public) server key.

To refresh after a RustDesk version bump: log into the console, rebuild the
`* admin` custom clients (they use RustDesk's ephemeral build server, so the
download URL expires), download the artifacts into `admin/`, and push.
