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

## Branded custom clients (normal + admin)

Two pre-built branded clients from the RustDesk Pro console are committed
here (Debian/Fedora/Arch each), both baking in the server address, api-server
and public key (no access password):

- `normal/` → **`gorm-help`** — locked down for supportees (settings, account
  and address book disabled; can't change the server).
- `admin/` → **`gorm-help-admin`** — full-control technician client (account
  login + address book enabled). App-name "Gorm-Help-Admin" so it installs
  under a distinct package name and can sit alongside `gorm-help`.

The build script folds both into the apt/dnf/pacman indexes:

```
sudo pacman -Sy gorm-help          # or apt / dnf install
sudo pacman -Sy gorm-help-admin
```

`gorm-help-admin` is intentionally **not** linked from the landing page or
blacklog.net (present in the index but unadvertised). The repos are public
and unauthenticated, so it's discoverable by listing the index; nothing in it
is secret beyond the (public) server key.

To refresh after a RustDesk version bump: console login (email MFA), rebuild
the `* help` and `* admin` custom clients (RustDesk's build server is
ephemeral, so download URLs expire), drop the artifacts into `normal/` and
`admin/`, and push.
