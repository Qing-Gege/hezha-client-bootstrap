#!/bin/zsh

set -euo pipefail
umask 077

readonly BOOTSTRAP_VERSION="1.0.3"
readonly RUNTIME_VERSION="1.0.0"
readonly PIXI_VERSION="0.76.2"
readonly OFFICECLI_RELEASE_VERSION="1.0.143"
readonly OFFICECLI_MINIMUM_VERSION="1.0.143"
readonly MINIMUM_FREE_SPACE_BYTES="1610612736"
readonly REPOSITORY="Qing-Gege/hezha-client-bootstrap"
readonly RUNTIME_REVISION="799cc8e9e88c3293a2f38e40bf0cad93703d663e"
readonly RUNTIME_BASE_URL="https://raw.githubusercontent.com/${REPOSITORY}/${RUNTIME_REVISION}/runtime/${RUNTIME_VERSION}"
readonly MANIFEST_URL="${RUNTIME_BASE_URL}/pixi.toml"
readonly MANIFEST_SIZE="509"
readonly MANIFEST_SHA256="43e641a0feab37c85f57d1fc578a7b990a59193cff8acb3e11594dd6df1b2428"
readonly LOCK_URL="${RUNTIME_BASE_URL}/pixi.lock"
readonly LOCK_SIZE="82251"
readonly LOCK_SHA256="8e5f2fbe189c18ca9a4e42ab94a1eaf457c44b8b1e4534c6745ab6b91834515c"
readonly REQUIRED_LANGUAGES=(eng chi_sim chi_tra osd)

WORK_DIR=""

fail() {
  print -u2 -r -- "LegalSkills bootstrap failed: $1"
  exit 1
}

progress() {
  print -u2 -r -- "[$1/6] $2"
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    /bin/rm -rf -- "${WORK_DIR}"
  fi
}

trap cleanup EXIT HUP INT TERM

sha256() {
  /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'
}

file_size() {
  /usr/bin/stat -f '%z' -- "$1"
}

verify_file() {
  local path="$1"
  local expected_size="$2"
  local expected_sha256="$3"
  local label="$4"

  [[ -f "${path}" ]] || fail "${label} was not downloaded"
  [[ "$(file_size "${path}")" == "${expected_size}" ]] || fail "${label} size mismatch"
  [[ "$(sha256 "${path}")" == "${expected_sha256}" ]] || fail "${label} SHA-256 mismatch"
}

verify_developer_id() {
  local path="$1"
  local expected_team="$2"
  local label="$3"
  local details

  /usr/bin/codesign --verify --strict --verbose=2 "${path}" >/dev/null 2>&1 \
    || fail "${label} code signature is invalid"
  details="$(/usr/bin/codesign -dv --verbose=4 "${path}" 2>&1)"
  print -r -- "${details}" | /usr/bin/grep -q '^Authority=Developer ID Application:' \
    || fail "${label} is not signed with Developer ID"
  print -r -- "${details}" | /usr/bin/grep -q "^TeamIdentifier=${expected_team}$" \
    || fail "${label} signer does not match the pinned publisher"
}

download() {
  local url="$1"
  local destination="$2"

  /usr/bin/curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --proto '=https' \
    --tlsv1.2 \
    --output "${destination}" \
    "${url}"
}

atomic_replace() {
  local source="$1"
  local destination="$2"
  local staged="${destination}.new.$$"

  /bin/mv -- "${source}" "${staged}"
  /bin/mv -f -- "${staged}" "${destination}"
}

json_result() {
  /usr/bin/osascript -l JavaScript \
    -e 'function run(a) { return JSON.stringify({status:a[0], reused:a[1] === "true", runtime_version:a[2], state_file:a[3]}); }' \
    "$1" "$2" "${RUNTIME_VERSION}" "${STATE_FILE}"
}

write_state() {
  local reused="$1"
  local verified_at
  local state_tmp="${STATE_FILE}.tmp.$$.json"

  verified_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
  /usr/bin/osascript -l JavaScript \
    -e '
function run(a) {
  const [runtimeVersion, arch, verifiedAt, pixi, manifest, officecli,
    officeVersion, popplerVersion, tesseractVersion] = a;
  const prefix = [pixi, "run", "--locked", "--no-config", "--manifest-path", manifest, "-x"];
  return JSON.stringify({
    schema_version: 1,
    runtime_version: runtimeVersion,
    os: "macos",
    arch: arch,
    verified_at: verifiedAt,
    pixi_path: pixi,
    manifest_path: manifest,
    officecli_path: officecli,
    commands: {
      officecli: [officecli],
      pdftotext: prefix.concat(["pdftotext"]),
      pdftoppm: prefix.concat(["pdftoppm"]),
      pdfseparate: prefix.concat(["pdfseparate"]),
      pdfunite: prefix.concat(["pdfunite"]),
      tesseract: prefix.concat(["tesseract"])
    },
    versions: {
      officecli: officeVersion,
      poppler: popplerVersion,
      tesseract: tesseractVersion
    },
    ocr_languages: ["eng", "chi_sim", "chi_tra", "osd"]
  }, null, 2);
}' \
    "${RUNTIME_VERSION}" "${ARCH}" "${verified_at}" "${PIXI_PATH}" \
    "${MANIFEST_PATH}" "${OFFICECLI_PATH}" "${OFFICECLI_ACTUAL_VERSION}" \
    "${POPPLER_ACTUAL_VERSION}" "${TESSERACT_ACTUAL_VERSION}" >"${state_tmp}"
  /usr/bin/osascript -l JavaScript \
    -e 'ObjC.import("Foundation"); function run(a) { const d=$.NSData.dataWithContentsOfFile(a[0]); if (!d) throw new Error("read failed"); const s=$.NSString.alloc.initWithDataEncoding(d,$.NSUTF8StringEncoding).js; const v=JSON.parse(s); if (v.schema_version !== 1) throw new Error("schema failed"); return "ok"; }' \
    "${state_tmp}" >/dev/null || fail "generated environment state is invalid"
  /bin/chmod 600 "${state_tmp}"
  /bin/mv -f -- "${state_tmp}" "${STATE_FILE}"
  json_result "ready" "${reused}"
}

run_pixi_tool() {
  "${PIXI_PATH}" run --locked --no-config --manifest-path "${MANIFEST_PATH}" -x "$@"
}

reported_version() {
  local output="$1"
  [[ "${output}" =~ '([0-9]+\.[0-9]+\.[0-9]+)' ]] || return 1
  print -r -- "${match[1]}"
}

version_at_least() {
  local actual="$1"
  local minimum="$2"
  local index
  local -a actual_parts
  local -a minimum_parts
  actual_parts=("${(@s:.:)actual}")
  minimum_parts=("${(@s:.:)minimum}")
  [[ "${#actual_parts}" -eq 3 && "${#minimum_parts}" -eq 3 ]] || return 1
  for index in 1 2 3; do
    (( actual_parts[index] > minimum_parts[index] )) && return 0
    (( actual_parts[index] < minimum_parts[index] )) && return 1
  done
  return 0
}

health_check() {
  local output
  local language
  local officecli_reported_version

  HEALTH_ERROR=""

  OFFICECLI_ACTUAL_VERSION="$("${OFFICECLI_PATH}" --version 2>&1 | /usr/bin/head -n 1 | /usr/bin/tr -d '\r')" || {
    HEALTH_ERROR="OfficeCLI --version failed"
    return 1
  }
  officecli_reported_version="$(reported_version "${OFFICECLI_ACTUAL_VERSION}")" || {
    HEALTH_ERROR="OfficeCLI returned an unrecognized version '${OFFICECLI_ACTUAL_VERSION}'; minimum required is ${OFFICECLI_MINIMUM_VERSION}"
    return 1
  }
  version_at_least "${officecli_reported_version}" "${OFFICECLI_MINIMUM_VERSION}" || {
    HEALTH_ERROR="OfficeCLI reported ${officecli_reported_version}; minimum required is ${OFFICECLI_MINIMUM_VERSION}"
    return 1
  }
  "${OFFICECLI_PATH}" help >/dev/null 2>&1 || {
    HEALTH_ERROR="OfficeCLI help failed"
    return 1
  }

  output="$(run_pixi_tool pdftotext -v 2>&1)" || {
    HEALTH_ERROR="pdftotext -v failed"
    return 1
  }
  POPPLER_ACTUAL_VERSION="$(print -r -- "${output}" | /usr/bin/head -n 1 | /usr/bin/tr -d '\r')"
  run_pixi_tool pdftoppm -v >/dev/null 2>&1 || {
    HEALTH_ERROR="pdftoppm -v failed"
    return 1
  }
  run_pixi_tool pdfseparate -v >/dev/null 2>&1 || {
    HEALTH_ERROR="pdfseparate -v failed"
    return 1
  }
  run_pixi_tool pdfunite -v >/dev/null 2>&1 || {
    HEALTH_ERROR="pdfunite -v failed"
    return 1
  }

  output="$(run_pixi_tool tesseract --version 2>&1)" || {
    HEALTH_ERROR="tesseract --version failed"
    return 1
  }
  TESSERACT_ACTUAL_VERSION="$(print -r -- "${output}" | /usr/bin/head -n 1 | /usr/bin/tr -d '\r')"
  output="$(run_pixi_tool tesseract --list-langs 2>&1)" || {
    HEALTH_ERROR="tesseract --list-langs failed"
    return 1
  }
  for language in "${REQUIRED_LANGUAGES[@]}"; do
    print -r -- "${output}" | /usr/bin/grep -qxF "${language}" || {
      HEALTH_ERROR="Tesseract language '${language}' is missing"
      return 1
    }
  done
}

can_reuse() {
  [[ -x "${PIXI_PATH}" && -x "${OFFICECLI_PATH}" ]] || return 1
  [[ -f "${MANIFEST_PATH}" && -f "${LOCK_PATH}" ]] || return 1
  [[ "$(sha256 "${MANIFEST_PATH}")" == "${MANIFEST_SHA256}" ]] || return 1
  [[ "$(sha256 "${LOCK_PATH}")" == "${LOCK_SHA256}" ]] || return 1
  [[ "$("${PIXI_PATH}" --version 2>/dev/null)" == *"${PIXI_VERSION}"* ]] || return 1
  verify_developer_id "${PIXI_PATH}" "69V3ZZ67U5" "Pixi"
  verify_developer_id "${OFFICECLI_PATH}" "52JQX2HUSC" "OfficeCLI"
  health_check
}

inspect() {
  local os_version
  local machine

  os_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
  machine="$(/usr/bin/uname -m 2>/dev/null || true)"
  /usr/bin/osascript -l JavaScript \
    -e 'function run(a) { return JSON.stringify({bootstrap_version:a[0], runtime_version:a[1], os:"macos", os_version:a[2], machine:a[3], user_scope_only:true, modifies_path:false, requires_admin:false}); }' \
    "${BOOTSTRAP_VERSION}" "${RUNTIME_VERSION}" "${os_version}" "${machine}"
}

install() {
  local os_version
  local os_major
  local machine
  local available_kib
  local minimum_kib
  local pixi_url
  local pixi_archive
  local pixi_size
  local pixi_sha256
  local officecli_url
  local officecli_download
  local officecli_size
  local officecli_sha256
  local failed=0
  local pid
  local archive_entries

  progress 1 "Checking platform, existing runtime, and free space"
  [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "macOS is required"
  os_version="$(/usr/bin/sw_vers -productVersion)"
  os_major="${os_version%%.*}"
  [[ "${os_major}" == <-> && "${os_major}" -ge 11 ]] || fail "macOS 11 or later is required"

  machine="$(/usr/bin/uname -m)"
  case "${machine}" in
    arm64)
      ARCH="arm64"
      pixi_url="https://github.com/prefix-dev/pixi/releases/download/v0.76.2/pixi-aarch64-apple-darwin.tar.gz"
      pixi_size="28699668"
      pixi_sha256="621c771029ecc785dcab3acf1db4671b8b2896e87c87d789160f8ed0d871335c"
      officecli_url="https://github.com/iOfficeAI/OfficeCLI/releases/download/v${OFFICECLI_RELEASE_VERSION}/officecli-mac-arm64"
      officecli_size="33740304"
      officecli_sha256="2f158d46f9b6c5eb0dfe4eb02038114001e17acc47b67347417c56dcf9659096"
      ;;
    x86_64)
      ARCH="x64"
      pixi_url="https://github.com/prefix-dev/pixi/releases/download/v0.76.2/pixi-x86_64-apple-darwin.tar.gz"
      pixi_size="32000272"
      pixi_sha256="e4b33400b8aa86b332e52f8eaa30590a78881998d897973439b382ef57ef0458"
      officecli_url="https://github.com/iOfficeAI/OfficeCLI/releases/download/v${OFFICECLI_RELEASE_VERSION}/officecli-mac-x64"
      officecli_size="34680704"
      officecli_sha256="693d243db616c74705fec9d92fdfc8a3db36acfcea378edb7264c2a30d339d9c"
      ;;
    *) fail "unsupported macOS architecture: ${machine}" ;;
  esac

  [[ "${HOME}" == /* ]] || fail "HOME must be an absolute path"
  BASE_DIR="${HOME}/Library/Application Support/LegalSkills"
  INSTALL_ROOT="${BASE_DIR}/runtime/${RUNTIME_VERSION}"
  STATE_FILE="${BASE_DIR}/environment.json"
  PIXI_PATH="${INSTALL_ROOT}/pixi"
  OFFICECLI_PATH="${INSTALL_ROOT}/officecli"
  MANIFEST_PATH="${INSTALL_ROOT}/pixi.toml"
  LOCK_PATH="${INSTALL_ROOT}/pixi.lock"

  [[ ! -L "${BASE_DIR}" && ! -L "${INSTALL_ROOT}" ]] || fail "install path must not be a symbolic link"
  /bin/mkdir -p -- "${INSTALL_ROOT}"

  if can_reuse; then
    progress 6 "Existing runtime is healthy; no download or reinstall was needed"
    write_state "true"
    return
  fi

  available_kib="$(/bin/df -Pk "${INSTALL_ROOT}" | /usr/bin/awk 'NR == 2 {print $4}')"
  minimum_kib="$(( (MINIMUM_FREE_SPACE_BYTES + 1023) / 1024 ))"
  [[ "${available_kib}" == <-> && "${available_kib}" -ge "${minimum_kib}" ]] \
    || fail "at least 1.5 GiB of free space is required"

  WORK_DIR="${INSTALL_ROOT}/.bootstrap.$$"
  /bin/mkdir -p -- "${WORK_DIR}/pixi-extract" "${WORK_DIR}/cache"
  pixi_archive="${WORK_DIR}/pixi.tar.gz"
  officecli_download="${WORK_DIR}/officecli"

  progress 2 "Downloading four pinned runtime files in parallel"
  download "${pixi_url}" "${pixi_archive}" &
  local pixi_pid=$!
  download "${officecli_url}" "${officecli_download}" &
  local office_pid=$!
  download "${MANIFEST_URL}" "${WORK_DIR}/pixi.toml" &
  local manifest_pid=$!
  download "${LOCK_URL}" "${WORK_DIR}/pixi.lock" &
  local lock_pid=$!
  for pid in "${pixi_pid}" "${office_pid}" "${manifest_pid}" "${lock_pid}"; do
    wait "${pid}" || failed=1
  done
  [[ "${failed}" == "0" ]] || fail "one or more runtime downloads failed"

  progress 3 "Verifying sizes, SHA-256 values, archive contents, and Developer ID signatures"
  verify_file "${pixi_archive}" "${pixi_size}" "${pixi_sha256}" "Pixi archive"
  verify_file "${officecli_download}" "${officecli_size}" "${officecli_sha256}" "OfficeCLI"
  verify_file "${WORK_DIR}/pixi.toml" "${MANIFEST_SIZE}" "${MANIFEST_SHA256}" "pixi.toml"
  verify_file "${WORK_DIR}/pixi.lock" "${LOCK_SIZE}" "${LOCK_SHA256}" "pixi.lock"
  archive_entries="$(/usr/bin/tar -tzf "${pixi_archive}")"
  [[ "${archive_entries}" == "pixi" ]] || fail "Pixi archive contains unexpected entries"
  /usr/bin/tar -xzf "${pixi_archive}" -C "${WORK_DIR}/pixi-extract"
  [[ -f "${WORK_DIR}/pixi-extract/pixi" ]] || fail "Pixi executable is missing from the archive"
  /bin/chmod 700 "${WORK_DIR}/pixi-extract/pixi" "${officecli_download}"
  verify_developer_id "${WORK_DIR}/pixi-extract/pixi" "69V3ZZ67U5" "Pixi"
  verify_developer_id "${officecli_download}" "52JQX2HUSC" "OfficeCLI"

  atomic_replace "${WORK_DIR}/pixi-extract/pixi" "${PIXI_PATH}"
  atomic_replace "${officecli_download}" "${OFFICECLI_PATH}"
  atomic_replace "${WORK_DIR}/pixi.toml" "${MANIFEST_PATH}"
  atomic_replace "${WORK_DIR}/pixi.lock" "${LOCK_PATH}"

  progress 4 "Installing the locked Poppler and Tesseract environment"
  PIXI_CACHE_DIR="${WORK_DIR}/cache" "${PIXI_PATH}" install \
    --locked \
    --no-config \
    --manifest-path "${MANIFEST_PATH}"

  progress 5 "Running OfficeCLI, Poppler, Tesseract, and OCR language health checks"
  health_check || fail "${HEALTH_ERROR:-one or more local tool health checks failed}"

  progress 6 "Writing the verified user environment state"
  write_state "false"
}

case "${1:-install}" in
  install) install ;;
  inspect) inspect ;;
  *) fail "usage: macos.sh [install|inspect]" ;;
esac
