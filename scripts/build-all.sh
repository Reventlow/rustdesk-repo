#!/usr/bin/env bash
# Build the complete Blacklog RustDesk package repository.
#
# Mirrors the latest official RustDesk release (deb/rpm/arch when present,
# Windows exe, macOS dmg), builds the rustdesk-blacklog-config companion
# package for each Linux format, and generates signed apt/dnf/pacman repo
# trees plus a downloads directory. Also mirrors the official Proton desktop
# apps (Mail, Pass, Authenticator, Meet; Stable channel, SHA512-verified)
# into the apt/dnf repos.
# Output lands in ./out ready to be copied into the nginx image.
#
# Requires: curl, jq, fpm, apt-utils (apt-ftparchive), createrepo-c, gpg,
# docker (for repo-add in an archlinux container).
set -euo pipefail

# Client configuration baked into every artifact.
RD_HOST="help.blacklog.net"
RD_KEY="kbvqsWFhZphFNcNOerLRtDCGVgD2ccSsTkE23JVXvxo="
CONFIG_PKG_VERSION="1.0.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
WORK="$ROOT/work"
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK"

# ---------------------------------------------------------------------
# 1. Resolve the latest upstream release and download its assets
# ---------------------------------------------------------------------
echo "==> Fetching latest RustDesk release metadata"
RELEASE_JSON="$WORK/release.json"
curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest -o "$RELEASE_JSON"
VERSION=$(jq -r '.tag_name' "$RELEASE_JSON" | sed 's/^v//')
echo "    upstream version: $VERSION"
echo "$VERSION" > "$OUT/VERSION"

download_assets() {
  # $1: jq filter matching asset names; $2: destination directory
  local filter="$1" dest="$2"
  mkdir -p "$dest"
  jq -r ".assets[] | select(.name | test(\"$filter\")) | .browser_download_url" "$RELEASE_JSON" |
    while read -r url; do
      echo "    downloading $(basename "$url")"
      curl -fsSL "$url" -o "$dest/$(basename "$url")"
    done
}

echo "==> Downloading upstream packages"
download_assets '^rustdesk-.*(x86_64|aarch64)\\.deb$'          "$WORK/deb"
download_assets '^rustdesk-.*\\.rpm$'                          "$WORK/rpm"
download_assets '^rustdesk-.*\\.pkg\\.tar\\.zst$'              "$WORK/arch"
download_assets '^rustdesk-.*-x86_64\\.exe$'                   "$WORK/win"
download_assets '^rustdesk-.*\\.dmg$'                          "$WORK/mac"
# openSUSE rpms would collide with the Fedora ones in one repo — drop them.
rm -f "$WORK"/rpm/*suse*.rpm

# ---------------------------------------------------------------------
# 1b. Mirror the official Proton desktop apps (deb/rpm, unchanged)
# ---------------------------------------------------------------------
# Proton ships its Linux apps only as direct downloads, and their Electron
# autoUpdater is a no-op on Linux — so without a repo the clients never
# update. For each app we take the newest *Stable* release from Proton's
# release feed (skipping Beta/EarlyAccess/Alpha), verify every file against
# the SHA512 Proton publishes there, and drop it into the same staging dirs
# so the apt/dnf indexers below pick it up. Any missing asset or checksum
# mismatch fails the whole build, leaving the published image in place.
#
# Proton Calendar has no Linux app of its own: it is built into Mail.
# Format: "<feed name under proton.me/download/>:<display name>"
PROTON_APPS=(
  "mail:Mail"
  "pass:Pass"
  "authenticator:Authenticator"
  "meet:Meet"
)

mirror_proton_file() {
  # $1: feed json; $2: version; $3: ext (deb|rpm); $4: dest dir; $5: app slug
  local json="$1" ver="$2" ext="$3" dest="$4" slug="$5" url sum file
  read -r url sum < <(jq -r --arg v "$ver" --arg ext ".$ext" '
    .Releases[] | select(.CategoryName == "Stable" and .Version == $v)
    | .File[] | select(.Url | endswith($ext)) | "\(.Url) \(.Sha512CheckSum)"' "$json" | head -1)
  [ -n "${url:-}" ] && [ -n "${sum:-}" ] && [ "$sum" != null ] ||
    { echo "No .$ext asset/checksum for Proton $slug $ver"; exit 1; }
  # Some upstream filenames carry no version (ProtonMail-desktop-beta.rpm);
  # give every mirrored copy a versioned name so pool/ stays unambiguous.
  file="$dest/proton-$slug-$ver.$ext"
  echo "    downloading $url"
  curl -fsSL "$url" -o "$file"
  echo "$sum  $file" | sha512sum -c --quiet - ||
    { echo "SHA512 mismatch for $url — refusing to publish"; exit 1; }
}

PROTON_SUMMARY=""
: > "$OUT/PROTON_VERSIONS"
for entry in "${PROTON_APPS[@]}"; do
  slug="${entry%%:*}" label="${entry#*:}"
  echo "==> Mirroring Proton $label (Stable channel)"
  json="$WORK/proton-$slug.json"
  curl -fsSL "https://proton.me/download/$slug/linux/version.json" -o "$json"
  ver=$(jq -r '.Releases[] | select(.CategoryName == "Stable") | .Version' "$json" | sort -V | tail -1)
  [ -n "$ver" ] || { echo "No Stable Proton $label release in feed"; exit 1; }
  echo "    $slug stable version: $ver"
  echo "$slug $ver" >> "$OUT/PROTON_VERSIONS"
  mirror_proton_file "$json" "$ver" deb "$WORK/deb" "$slug"
  mirror_proton_file "$json" "$ver" rpm "$WORK/rpm" "$slug"
  PROTON_SUMMARY="${PROTON_SUMMARY:+$PROTON_SUMMARY, }$label $ver"
done
# Kept for anything that already reads the single-app file.
awk '$1 == "mail" {print $2}' "$OUT/PROTON_VERSIONS" > "$OUT/PROTON_MAIL_VERSION"

# ---------------------------------------------------------------------
# 2. Build the rustdesk-blacklog-config companion package (deb/rpm/arch)
# ---------------------------------------------------------------------
echo "==> Building rustdesk-blacklog-config $CONFIG_PKG_VERSION"
PKGROOT="$WORK/config-pkg"
mkdir -p "$PKGROOT/usr/share/rustdesk-blacklog"
cat > "$PKGROOT/usr/share/rustdesk-blacklog/server.conf" <<EOF
# Blacklog RustDesk server configuration (applied by the package post-install)
RENDEZVOUS_SERVER=$RD_HOST
RELAY_SERVER=$RD_HOST
KEY=$RD_KEY
EOF

cat > "$WORK/postinstall.sh" <<EOF
#!/bin/sh
# Point the RustDesk service at the Blacklog server. The service runs as
# root, so root-level options govern unattended access for this machine.
if command -v rustdesk >/dev/null 2>&1; then
    rustdesk --option custom-rendezvous-server "$RD_HOST" || true
    rustdesk --option relay-server "$RD_HOST" || true
    rustdesk --option key "$RD_KEY" || true
    systemctl try-restart rustdesk 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$WORK/postinstall.sh"

fpm_common=(
  -s dir -n rustdesk-blacklog-config -v "$CONFIG_PKG_VERSION"
  --description "Preconfigures RustDesk for the Blacklog server ($RD_HOST)"
  --url "https://blacklog.net" --maintainer "Gorm Reventlow <gorm@reventlow.com>"
  --license MIT --after-install "$WORK/postinstall.sh" -C "$PKGROOT" -a all
)
fpm -t deb    -p "$WORK/deb/"  -d rustdesk "${fpm_common[@]}" usr
fpm -t rpm    -p "$WORK/rpm/"  -d rustdesk "${fpm_common[@]}" usr
fpm -t pacman -p "$WORK/arch/" -d rustdesk "${fpm_common[@]}" usr

# Pre-built branded custom clients from the RustDesk console, committed here:
#   normal/  -> gorm-help        (locked-down client for supportees)
#   admin/   -> gorm-help-admin  (full-control technician client)
# Both bake in the server address + public key (no access password). They are
# dropped into the same staging dirs so the indexers below pick them up. The
# admin package is deliberately NOT listed on the landing page or blacklog.net.
# For pacman the admin client gets its own repo (/arch-admin, step 6b) instead
# of riding in the public [blacklog] index; its install snippet lives on the
# private dashy.blacklog.net start page.
for d in normal admin; do
  if [ -d "$ROOT/$d" ]; then
    echo "==> Including $d client packages"
    cp "$ROOT/$d"/*.deb          "$WORK/deb/"  2>/dev/null || true
    cp "$ROOT/$d"/*.rpm          "$WORK/rpm/"  2>/dev/null || true
  fi
done
cp "$ROOT"/normal/*.pkg.tar.zst "$WORK/arch/" 2>/dev/null || true
mkdir -p "$WORK/arch-admin"
cp "$ROOT"/admin/*.pkg.tar.zst  "$WORK/arch-admin/" 2>/dev/null || true

# ---------------------------------------------------------------------
# 3. GPG: import the signing key, export the public part for clients
# ---------------------------------------------------------------------
echo "==> Preparing GPG signing key"
GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')
[ -n "$GPG_KEY_ID" ] || { echo "No GPG secret key in keyring"; exit 1; }
gpg --armor --export "$GPG_KEY_ID" > "$OUT/blacklog-repo.key"

# ---------------------------------------------------------------------
# 4. apt repository
# ---------------------------------------------------------------------
echo "==> Building apt repository"
APT="$OUT/apt"
mkdir -p "$APT/pool/main" "$APT/dists/stable/main/binary-amd64" "$APT/dists/stable/main/binary-arm64"
cp "$WORK"/deb/*.deb "$APT/pool/main/"
cd "$APT"
# NOTE: `apt-ftparchive --arch X packages` does NOT filter to that arch — it
# silently drops every real arch package and keeps only Architecture:all, so
# it must not be used here. Generate the full index once (all stanzas) and
# serve it for both arches; apt selects installable candidates by each
# package's Architecture: field, ignoring foreign-arch stanzas.
apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages
cp dists/stable/main/binary-amd64/Packages dists/stable/main/binary-arm64/Packages
for d in dists/stable/main/binary-amd64 dists/stable/main/binary-arm64; do gzip -kf "$d/Packages"; done
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=Blacklog \
  -o APT::FTPArchive::Release::Label=Blacklog \
  -o APT::FTPArchive::Release::Suite=stable \
  -o APT::FTPArchive::Release::Codename=stable \
  -o APT::FTPArchive::Release::Architectures="amd64 arm64" \
  -o APT::FTPArchive::Release::Components=main \
  release dists/stable > dists/stable/Release
gpg --default-key "$GPG_KEY_ID" --batch --yes --clearsign -o dists/stable/InRelease dists/stable/Release
gpg --default-key "$GPG_KEY_ID" --batch --yes -abs -o dists/stable/Release.gpg dists/stable/Release
cd "$ROOT"

# ---------------------------------------------------------------------
# 5. dnf/rpm repository
# ---------------------------------------------------------------------
echo "==> Building rpm repository"
RPM="$OUT/rpm"
mkdir -p "$RPM"
cp "$WORK"/rpm/*.rpm "$RPM/"
createrepo_c "$RPM"
gpg --default-key "$GPG_KEY_ID" --batch --yes --detach-sign --armor "$RPM/repodata/repomd.xml"

# ---------------------------------------------------------------------
# 6. pacman repository (repo-add runs in an archlinux container)
# ---------------------------------------------------------------------
echo "==> Building pacman repository"
ARCH="$OUT/arch"
mkdir -p "$ARCH"
cp "$WORK"/arch/*.pkg.tar.zst "$ARCH/" 2>/dev/null || echo "    (no upstream arch package this release — config package only)"
docker run --rm -v "$ARCH":/repo archlinux:latest \
  bash -c "repo-add /repo/blacklog.db.tar.gz /repo/*.pkg.tar.zst"

# 6b. Separate pacman repository for the technician client. Same server key,
# distinct db name so it is added as its own [blacklog-admin] entry:
#   [blacklog-admin]
#   SigLevel = Optional TrustAll
#   Server = https://pkgs.blacklog.net/arch-admin
echo "==> Building pacman admin repository"
ARCH_ADMIN="$OUT/arch-admin"
mkdir -p "$ARCH_ADMIN"
if cp "$WORK"/arch-admin/*.pkg.tar.zst "$ARCH_ADMIN/" 2>/dev/null; then
  docker run --rm -v "$ARCH_ADMIN":/repo archlinux:latest \
    bash -c "repo-add /repo/blacklog-admin.db.tar.gz /repo/*.pkg.tar.zst"
else
  echo "    (no admin arch package committed — skipping)"
fi

# ---------------------------------------------------------------------
# 7. Windows + macOS downloads (filename-embedded config for Windows)
# ---------------------------------------------------------------------
echo "==> Preparing Windows and macOS downloads"
DL="$OUT/downloads"
mkdir -p "$DL"
# Renaming the official installer embeds the config: RustDesk parses
# host=...,key=... out of its own executable name on first run.
WIN_EXE=$(ls "$WORK"/win/rustdesk-*-x86_64.exe 2>/dev/null | head -1 || true)
if [ -n "$WIN_EXE" ]; then
  cp "$WIN_EXE" "$DL/rustdesk-host=$RD_HOST,key=$RD_KEY.exe"
  cp "$WIN_EXE" "$DL/$(basename "$WIN_EXE")"
fi
cp "$WORK"/mac/*.dmg "$DL/" 2>/dev/null || true
# Stable-named copies so external links (blacklog.net) survive version bumps.
for arch in x86_64 aarch64; do
  src=$(ls "$WORK"/mac/rustdesk-*-$arch.dmg 2>/dev/null | head -1 || true)
  [ -n "$src" ] && cp "$src" "$DL/rustdesk-latest-$arch.dmg"
done

# Silent-deploy script for Windows fleets.
sed -e "s|@HOST@|$RD_HOST|g" -e "s|@KEY@|$RD_KEY|g" -e "s|@VERSION@|$VERSION|g" \
  "$ROOT/scripts/install.ps1.tmpl" > "$DL/install-blacklog-rustdesk.ps1"

# macOS post-install one-liner, documented on the landing page.
cat > "$DL/macos-configure.sh" <<EOF
#!/bin/sh
# Run once after installing RustDesk.app to point it at the Blacklog server.
/Applications/RustDesk.app/Contents/MacOS/rustdesk --option custom-rendezvous-server "$RD_HOST"
/Applications/RustDesk.app/Contents/MacOS/rustdesk --option relay-server "$RD_HOST"
/Applications/RustDesk.app/Contents/MacOS/rustdesk --option key "$RD_KEY"
EOF

# ---------------------------------------------------------------------
# 8. Landing page
# ---------------------------------------------------------------------
sed -e "s|@VERSION@|$VERSION|g" -e "s|@HOST@|$RD_HOST|g" -e "s|@KEY@|$RD_KEY|g" \
  -e "s|@PROTON_APPS@|$PROTON_SUMMARY|g" \
  "$ROOT/web/index.html.tmpl" > "$OUT/index.html"

echo "==> Done. Repo tree in $OUT (upstream $VERSION)"
