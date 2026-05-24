#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${REPOSITORY:-NexWan/nexdev-cli}"
VERSION="${VERSION:-latest}"

fail() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "nexdev-cli: $*"
}

fetch_stdout() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
    return
  fi

  fail "curl or wget is required"
}

download_file() {
  local url="$1"
  local destination="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$destination" "$url" && return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -O "$destination" "$url" && return 0
  fi

  return 1
}

detect_os_name() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
    *)
      fail "unsupported OS: $(uname -s)"
      ;;
  esac
}

detect_arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)
      fail "unsupported architecture: $(uname -m)"
      ;;
  esac
}

resolve_latest_version() {
  local json
  local tag

  json="$(fetch_stdout "https://api.github.com/repos/${REPOSITORY}/releases/latest")"
  tag="$(printf '%s\n' "$json" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"

  if [[ -z "$tag" ]]; then
    fail "could not resolve the latest release for ${REPOSITORY}"
  fi

  printf '%s\n' "$tag"
}

verify_checksum() {
  local archive_name="$1"
  local checksum_name="$2"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "$checksum_name"
    return
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$checksum_name"
    return
  fi

  info "no SHA-256 tool found; skipping checksum verification"
  return 0
}

if ! command -v tar >/dev/null 2>&1; then
  fail "tar is required"
fi

OS_NAME="$(detect_os_name)"
ARCH_NAME="$(detect_arch_name)"
TARGET_NAME="${OS_NAME}-${ARCH_NAME}"

if [[ "$VERSION" == "latest" ]]; then
  VERSION="$(resolve_latest_version)"
fi

ARCHIVE_NAME="nexdev-cli-${VERSION}-${TARGET_NAME}.tar.gz"
RELEASE_URL="https://github.com/${REPOSITORY}/releases/download/${VERSION}"
ARCHIVE_URL="${RELEASE_URL}/${ARCHIVE_NAME}"
CHECKSUM_URL="${ARCHIVE_URL}.sha256"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$TMP_DIR/$ARCHIVE_NAME.sha256"

info "downloading ${ARCHIVE_NAME}"
if ! download_file "$ARCHIVE_URL" "$ARCHIVE_PATH"; then
  fail "could not download ${ARCHIVE_URL}"
fi

if download_file "$CHECKSUM_URL" "$CHECKSUM_PATH"; then
  info "verifying checksum"
  (cd "$TMP_DIR" && verify_checksum "$ARCHIVE_NAME" "$ARCHIVE_NAME.sha256")
else
  info "checksum not found; continuing without checksum verification"
fi

info "extracting archive"
tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"

PACKAGE_DIR="$TMP_DIR/nexdev-cli-${VERSION}-${TARGET_NAME}"
if [[ ! -x "$PACKAGE_DIR/install.sh" ]]; then
  fail "release archive did not contain an executable install.sh"
fi

info "installing ${VERSION} for ${TARGET_NAME}"
bash "$PACKAGE_DIR/install.sh"
