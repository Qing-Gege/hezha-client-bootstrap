#!/bin/zsh

set -euo pipefail
umask 077

readonly SKILL_VERSION="1.6.0"
readonly SKILL_RELEASE_TAG="v1.0.7"
readonly SKILL_BUNDLE_NAME="KaodaWoSkills-v${SKILL_VERSION}.zip"
readonly SKILL_BUNDLE_URL="https://github.com/Qing-Gege/hezha-client-bootstrap/releases/download/${SKILL_RELEASE_TAG}/${SKILL_BUNDLE_NAME}"
readonly SKILL_BUNDLE_SIZE="18264"
readonly SKILL_BUNDLE_SHA256="1ea0d60bcbcd13ecbb4294ece3de75f868c529ee9ff69ac0f7ceae4611e80496"

fail() {
  print -u2 -- "HeZha kaoda-wo install failed: $1"
  exit 1
}

sha256() {
  /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'
}

file_size() {
  /usr/bin/stat -f '%z' -- "$1"
}

download() {
  /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --output "$2" "$1"
}

client="${1:-}"
[[ "$client" == "codex" || "$client" == "claude" ]] || fail "usage: install-kaoda-macos.sh [codex|claude]"
[[ "${HOME:-}" == /* ]] || fail "HOME must be an absolute path"

case "$client" in
  codex) client_root="$HOME/.codex/skills" ;;
  claude) client_root="$HOME/.claude/skills" ;;
esac

[[ ! -L "$client_root" ]] || fail "client skill directory must not be a symbolic link"
/bin/mkdir -p -- "$client_root"
target="$client_root/kaoda-wo"
[[ ! -L "$target" ]] || fail "kaoda-wo target must not be a symbolic link"

work_root="$HOME/Library/Application Support/LegalSkills/.kaoda-wo.$$"
/bin/mkdir -p -- "$work_root"
cleanup() { /bin/rm -rf -- "$work_root"; }
trap cleanup EXIT HUP INT TERM

bundle="$work_root/$SKILL_BUNDLE_NAME"
download "$SKILL_BUNDLE_URL" "$bundle"
[[ "$(file_size "$bundle")" == "$SKILL_BUNDLE_SIZE" ]] || fail "bundle size mismatch"
[[ "$(sha256 "$bundle")" == "$SKILL_BUNDLE_SHA256" ]] || fail "bundle SHA-256 mismatch"

extract="$work_root/extract"
/bin/mkdir -p -- "$extract"
/usr/bin/unzip -q "$bundle" -d "$extract"
for required in "manifest.json" "protocol.json" "clients/$client/SKILL.md"; do
  [[ -f "$extract/$required" ]] || fail "bundle is missing $required"
done

staged="$client_root/.kaoda-wo.new.$$"
backup="$client_root/.kaoda-wo.backup.$$"
/bin/mkdir -p -- "$staged"
/bin/cp -p -- "$extract/manifest.json" "$staged/manifest.json"
/bin/cp -p -- "$extract/protocol.json" "$staged/protocol.json"
/bin/cp -p -- "$extract/clients/$client/SKILL.md" "$staged/SKILL.md"
/bin/chmod 600 "$staged/manifest.json" "$staged/protocol.json" "$staged/SKILL.md"

if [[ -e "$target" ]]; then
  /bin/mv -- "$target" "$backup"
fi
if ! /bin/mv -- "$staged" "$target"; then
  [[ -e "$backup" ]] && /bin/mv -- "$backup" "$target"
  fail "could not publish kaoda-wo"
fi
/bin/rm -rf -- "$backup"

/usr/bin/osascript -l JavaScript -e 'function run(a) { return JSON.stringify({status:"ready", skill_id:"kaoda-wo", version:a[0], client:a[1], path:a[2], user_scope_only:true}); }' \
  "$SKILL_VERSION" "$client" "$target"
