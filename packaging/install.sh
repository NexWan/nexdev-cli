#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_os_name() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
    *)
      echo "Unsupported OS: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

default_bin_dir() {
  if [[ -n "${PREFIX:-}" ]]; then
    printf '%s\n' "$PREFIX/bin"
    return
  fi

  case "$OS_NAME" in
    windows)
      local local_app_data="${LOCALAPPDATA:-$HOME/AppData/Local}"
      printf '%s\n' "$local_app_data/Programs/nexdev-cli/bin"
      ;;
    linux|macos)
      printf '%s\n' "$HOME/.local/bin"
      ;;
  esac
}

default_lib_dir() {
  if [[ -n "${PREFIX:-}" ]]; then
    printf '%s\n' "$PREFIX/lib/nexdev-cli"
    return
  fi

  case "$OS_NAME" in
    windows)
      local local_app_data="${LOCALAPPDATA:-$HOME/AppData/Local}"
      printf '%s\n' "$local_app_data/nexdev-cli"
      ;;
    macos)
      printf '%s\n' "$HOME/Library/Application Support/nexdev-cli"
      ;;
    linux)
      local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
      printf '%s\n' "$data_home/nexdev-cli"
      ;;
  esac
}

to_windows_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

OS_NAME="$(detect_os_name)"
EXE_EXT=""
if [[ "$OS_NAME" == "windows" ]]; then
  EXE_EXT=".exe"
fi

BIN_DIR="${BIN_DIR:-$(default_bin_dir)}"
LIB_DIR="${LIB_DIR:-$(default_lib_dir)}"
RUNTIME_SOURCE="$SOURCE_DIR/lib/nexdev-cli"
BINARY_SOURCE="$SOURCE_DIR/bin/nexdev_cli$EXE_EXT"
BINARY_DEST="$LIB_DIR/bin/nexdev_cli$EXE_EXT"
LAUNCHER_DEST="$BIN_DIR/nexdev-cli"
CMD_LAUNCHER_DEST="$BIN_DIR/nexdev-cli.cmd"

if [[ ! -x "$BINARY_SOURCE" ]]; then
  echo "Missing packaged binary: $BINARY_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$RUNTIME_SOURCE/agent/rpc-module.ts" ]]; then
  echo "Missing packaged TypeScript runtime: $RUNTIME_SOURCE" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js 22.6 or newer is required on PATH." >&2
  exit 1
fi

NODE_VERSION="$(node -p "process.versions.node")"
NODE_MAJOR="${NODE_VERSION%%.*}"
NODE_MINOR_PATCH="${NODE_VERSION#*.}"
NODE_MINOR="${NODE_MINOR_PATCH%%.*}"
if (( NODE_MAJOR < 22 || (NODE_MAJOR == 22 && NODE_MINOR < 6) )); then
  echo "Node.js 22.6 or newer is required; found $NODE_VERSION." >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$LIB_DIR/bin"
rm -rf "$LIB_DIR/agent" "$LIB_DIR/node_modules"
cp -R "$RUNTIME_SOURCE/agent" "$LIB_DIR/agent"
cp -R "$RUNTIME_SOURCE/node_modules" "$LIB_DIR/node_modules"
cp "$RUNTIME_SOURCE/package.json" "$RUNTIME_SOURCE/package-lock.json" "$LIB_DIR/"
cp "$BINARY_SOURCE" "$BINARY_DEST"
chmod 755 "$BINARY_DEST"

cat > "$LAUNCHER_DEST" <<EOF
#!/usr/bin/env bash
export NEXDEV_CLI_LIB_DIR="$LIB_DIR"
exec "$BINARY_DEST" "\$@"
EOF
chmod 755 "$LAUNCHER_DEST"

if [[ "$OS_NAME" == "windows" ]]; then
  WINDOWS_LIB_DIR="$(to_windows_path "$LIB_DIR")"
  WINDOWS_BINARY_DEST="$(to_windows_path "$BINARY_DEST")"
  cat > "$CMD_LAUNCHER_DEST" <<EOF
@echo off
set "NEXDEV_CLI_LIB_DIR=$WINDOWS_LIB_DIR"
"$WINDOWS_BINARY_DEST" %*
EOF
fi

echo "Installed nexdev-cli to $LAUNCHER_DEST"
if [[ "$OS_NAME" == "windows" ]]; then
  echo "Installed Windows launcher to $CMD_LAUNCHER_DEST"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "Add $BIN_DIR to PATH to run nexdev-cli from any shell."
    ;;
esac
