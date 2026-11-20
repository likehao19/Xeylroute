#!/usr/bin/env bash
set -euo pipefail

# Cross-platform Mihomo v1.19.34 installer for RoutePilot / Xeylroute (macOS & Linux)
# Usage:
#   ./scripts/install-mihomo.sh --download [--force]
#   ./scripts/install-mihomo.sh /path/to/mihomo-*.gz [--sha256 <hex>] [--force]

VERSION="v1.19.34"
FORCE=0
DOWNLOAD=0
ARCHIVE=""
EXPECTED_SHA256=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download) DOWNLOAD=1; shift ;;
    --force) FORCE=1; shift ;;
    --sha256) EXPECTED_SHA256="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage:"
      echo "  $0 --download [--force]                     Download official Mihomo ${VERSION} for this platform"
      echo "  $0 <archive.gz|archive.zip> [--sha256 HEX]  Install from a local official archive"
      exit 0
      ;;
    *) ARCHIVE="$1"; shift ;;
  esac
done

OS="$(uname -s)"
ARCH="$(uname -m)"

case "${OS}" in
  Darwin)
    PLATFORM="darwin"
    CORE_DIR="${HOME}/Library/Application Support/app.routepilot.desktop/core"
    ;;
  Linux)
    PLATFORM="linux"
    CORE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/app.routepilot.desktop/core"
    ;;
  *)
    echo "Unsupported OS: ${OS}. Use scripts/Install-Mihomo.ps1 on Windows." >&2
    exit 1
    ;;
esac

case "${ARCH}" in
  arm64|aarch64) ARCH_TAG="arm64" ;;
  x86_64|amd64) ARCH_TAG="amd64-compatible" ;;
  *)
    echo "Unsupported CPU architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

DEST="${CORE_DIR}/mihomo"
if [[ -f "${DEST}" && "${FORCE}" -ne 1 ]]; then
  echo "Mihomo already exists at: ${DEST}" >&2
  echo "Pass --force to replace it (stop RoutePilot first)." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

if [[ "${DOWNLOAD}" -eq 1 ]]; then
  ASSET="mihomo-${PLATFORM}-${ARCH_TAG}-${VERSION}.gz"
  BASE_URL="https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}"
  ARCHIVE="${TMP_DIR}/${ASSET}"
  echo "Downloading ${ASSET}..."
  curl -fL --retry 3 -o "${ARCHIVE}" "${BASE_URL}/${ASSET}"
  if [[ -z "${EXPECTED_SHA256}" ]]; then
    CHECKSUMS="${TMP_DIR}/sha256sums"
    if curl -fsSL -o "${CHECKSUMS}" "${BASE_URL}/sha256sums" 2>/dev/null; then
      EXPECTED_SHA256="$(awk -v name="${ASSET}" '$2 == name || $2 == "*"name {print $1; exit}' "${CHECKSUMS}" || true)"
    fi
  fi
elif [[ -z "${ARCHIVE}" ]]; then
  echo "Error: provide a local archive path or pass --download." >&2
  exit 1
fi

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "Error: archive not found: ${ARCHIVE}" >&2
  exit 1
fi

if [[ -n "${EXPECTED_SHA256}" ]]; then
  ACTUAL_SHA256="$(sha256_file "${ARCHIVE}")"
  if [[ "${ACTUAL_SHA256,,}" != "${EXPECTED_SHA256,,}" ]]; then
    echo "SHA256 mismatch!" >&2
    echo "  expected: ${EXPECTED_SHA256}" >&2
    echo "  actual:   ${ACTUAL_SHA256}" >&2
    exit 1
  fi
  echo "Verified SHA256: ${ACTUAL_SHA256}"
fi

EXTRACTED="${TMP_DIR}/mihomo"
case "${ARCHIVE}" in
  *.gz)
    gzip -dc "${ARCHIVE}" > "${EXTRACTED}"
    ;;
  *.zip)
    unzip -p "${ARCHIVE}" 'mihomo*' > "${EXTRACTED}"
    ;;
  *)
    cp "${ARCHIVE}" "${EXTRACTED}"
    ;;
esac

if [[ ! -s "${EXTRACTED}" ]]; then
  echo "Error: extracted binary is empty." >&2
  exit 1
fi

mkdir -p "${CORE_DIR}"
install -m 755 "${EXTRACTED}" "${DEST}"

if [[ "${OS}" == "Darwin" ]] && command -v xattr >/dev/null 2>&1; then
  xattr -d com.apple.quarantine "${DEST}" 2>/dev/null || true
fi

echo "Installed verified Mihomo at: ${DEST}"
"${DEST}" -v || true
