#!/usr/bin/env bash
# Rebuild the branded custom clients from the RustDesk Pro console and drop
# them into normal/ and admin/ ready to commit. Run when the version-check
# notifier says the client is newer than what the branded packages ship.
#
# The console requires email MFA, so this is not fully unattended: it pauses
# once for the code. Everything else — login, triggering the 6 builds, polling,
# downloading, replacing the old files — is automatic.
#
# Requires: curl, jq, uuidgen.
# Credentials come from the environment (NEVER hard-code — this repo is public):
#   RUSTDESK_URL       console base URL   (default https://help.blacklog.net)
#   RUSTDESK_USERNAME  console admin user (default admin)
#   RUSTDESK_PASSWORD  console password   (prompted if unset)
set -euo pipefail

URL="${RUSTDESK_URL:-https://help.blacklog.net}"
USER="${RUSTDESK_USERNAME:-admin}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Console client name -> "<repo dir> <file extension>". The extension follows
# the distro; the repo dir decides normal (gorm-help) vs admin (gorm-help-admin).
declare -A DEST=(
  ["Arch help"]="normal pkg.tar.zst"
  ["Debian/Ubuntu help"]="normal deb"
  ["Fedora help"]="normal rpm"
  ["Arch admin"]="admin pkg.tar.zst"
  ["Debian admin"]="admin deb"
  ["Fedora admin"]="admin rpm"
)

if [ -z "${RUSTDESK_PASSWORD:-}" ]; then
  read -rsp "RustDesk console password for $USER: " RUSTDESK_PASSWORD; echo
fi

UUID="$(uuidgen | tr -d '\n' | base64)"
DEVINFO='{"os":"linux","type":"webadmin","name":"rebuild-branded"}'

login() {  # $1 extra JSON fields (e.g. verificationCode); echoes the response
  curl -fsS -X POST "$URL/api/login" -H 'Content-Type: application/json' -d "{
    \"username\":\"$USER\",\"password\":\"$RUSTDESK_PASSWORD\",\"id\":\"\",
    \"uuid\":\"$UUID\",\"autoLogin\":true,\"deviceInfo\":$DEVINFO$1}"
}

echo "==> Logging in to $URL as $USER"
resp="$(login ',"type":"account"')"
TOKEN="$(jq -r '.access_token // empty' <<<"$resp")"
if [ "$(jq -r '.type // empty' <<<"$resp")" = "email_check" ]; then
  read -rp "MFA code emailed to the $USER account: " CODE
  resp="$(login ",\"type\":\"email_code\",\"verificationCode\":\"$CODE\"")"
  TOKEN="$(jq -r '.access_token // empty' <<<"$resp")"
fi
[ -n "$TOKEN" ] || { echo "Login failed: $resp" >&2; exit 1; }
echo "    logged in."

VER="$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
echo "==> Building branded clients for client version $VER"

CLIENTS="$(curl -fsS "$URL/api/custom-clients?current=1&pageSize=50" -H "Authorization: Bearer $TOKEN")"

build_one() {  # $1 console client name
  local name="$1" guid dir ext pkg id file out st state
  read -r dir ext <<<"${DEST[$name]}"
  guid="$(jq -r --arg n "$name" '.data[] | select(.name==$n) | .guid' <<<"$CLIENTS" | head -1)"
  [ -n "$guid" ] || { echo "!! console client '$name' not found — skipping" >&2; return 1; }

  echo "==> $name  ->  $dir/ (.$ext)"
  curl -fsS -X POST "$URL/api/custom-clients/$guid/create" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d '{}' >/dev/null

  for _ in $(seq 1 80); do
    st="$(curl -fsS -X POST "$URL/api/custom-clients/$guid/status" -H "Authorization: Bearer $TOKEN" \
          -H 'Content-Type: application/json' -d '{}' || true)"
    state="$(jq -r '.state // "?"' <<<"$st" 2>/dev/null || echo '?')"
    if [ "$state" = "done" ]; then
      id="$(jq -r '.id' <<<"$st")"; file="$(jq -r '.file' <<<"$st")"
      pkg="gorm-help"; [ "$dir" = admin ] && pkg="gorm-help-admin"
      out="$ROOT/$dir/$pkg-$VER-x86_64.$ext"
      curl -fsSL "https://rustdesk.com/build/tasks/$id/files/$file" -o "$out"
      echo "    saved $out ($(du -h "$out" | cut -f1))"
      return 0
    fi
    sleep 15
  done
  echo "!! timed out building $name" >&2; return 1
}

for name in "Arch help" "Debian/Ubuntu help" "Fedora help" "Arch admin" "Debian admin" "Fedora admin"; do
  build_one "$name"
done

# Drop any files from a previous version so each dir holds only VER.
for d in normal admin; do
  find "$ROOT/$d" -type f ! -name "*-$VER-*" -delete 2>/dev/null || true
done

echo
echo "==> Done. Review then push:"
echo "    git -C \"$ROOT\" add normal/ admin/ && \\"
echo "    git -C \"$ROOT\" commit -m \"clients: rebuild branded packages for $VER\" && \\"
echo "    git -C \"$ROOT\" push"
