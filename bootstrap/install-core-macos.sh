#!/bin/zsh

set -euo pipefail
umask 077

readonly SKILL_VERSION="0.6.0"
readonly SKILL_RELEASE_TAG="v1.0.15"
readonly SKILL_BUNDLE_NAME="CoreSkills-v${SKILL_VERSION}.zip"
readonly SKILL_BUNDLE_URL="https://github.com/Qing-Gege/hezha-client-bootstrap/releases/download/${SKILL_RELEASE_TAG}/${SKILL_BUNDLE_NAME}"
readonly SKILL_BUNDLE_SIZE="70658"
readonly SKILL_BUNDLE_SHA256="ae0fed1c3305ef621ef3009e8cc3cdc2f4e44b20f78de0ca0a36f1bc2cf12972"
readonly SKILL_IDS=(document-operations document-ocr diagramming source skill-authoring)

fail() {
  print -u2 -- "HeZha core skills install failed: $1"
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
[[ "$client" == "codex" || "$client" == "claude" ]] || fail "usage: install-core-macos.sh [codex|claude]"
[[ "${HOME:-}" == /* ]] || fail "HOME must be an absolute path"

case "$client" in
  codex) client_root="$HOME/.codex/skills" ;;
  claude) client_root="$HOME/.claude/skills" ;;
esac

[[ ! -L "$client_root" ]] || fail "client skill directory must not be a symbolic link"
/bin/mkdir -p -- "$client_root"

work_root="$HOME/Library/Application Support/LegalSkills/.core-skills.$$"
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
[[ -f "$extract/manifest.json" ]] || fail "bundle is missing manifest.json"

installed_paths=()
for skill_id in "${SKILL_IDS[@]}"; do
  for required in "skills/$skill_id/manifest.json" "skills/$skill_id/clients/$client/SKILL.md"; do
    [[ -f "$extract/$required" ]] || fail "bundle is missing $required"
  done
  target="$client_root/$skill_id"
  [[ ! -L "$target" ]] || fail "$skill_id target must not be a symbolic link"
  staged="$client_root/.$skill_id.new.$$"
  backup="$client_root/.$skill_id.backup.$$"
  /bin/rm -rf -- "$staged"
  /bin/mkdir -p -- "$staged"
  /bin/cp -p -- "$extract/skills/$skill_id/manifest.json" "$staged/manifest.json"
  /bin/cp -p -- "$extract/skills/$skill_id/clients/$client/SKILL.md" "$staged/SKILL.md"
  /bin/chmod 600 "$staged/manifest.json" "$staged/SKILL.md"
  if [[ -e "$target" ]]; then
    /bin/mv -- "$target" "$backup"
  fi
  if ! /bin/mv -- "$staged" "$target"; then
    [[ -e "$backup" ]] && /bin/mv -- "$backup" "$target"
    fail "could not publish $skill_id"
  fi
  /bin/rm -rf -- "$backup"
  installed_paths+="$target"
done

/usr/bin/osascript -l JavaScript -e 'function run(a) { return JSON.stringify({status:"ready", pack_id:"core", version:a[0], client:a[1], skill_ids:a[2].split(","), paths:a[3].split(","), user_scope_only:true}); }' \
  "$SKILL_VERSION" "$client" "${(j:,:)SKILL_IDS}" "${(j:,:)installed_paths}"
