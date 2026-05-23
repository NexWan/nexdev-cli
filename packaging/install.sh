#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
LIB_DIR="${LIB_DIR:-$PREFIX/lib/nexdev-cli}"
RUNTIME_SOURCE="$SOURCE_DIR/lib/nexdev-cli"
BINARY_SOURCE="$SOURCE_DIR/bin/nexdev_cli"
BINARY_DEST="$LIB_DIR/bin/nexdev_cli"
LAUNCHER_DEST="$BIN_DIR/nexdev-cli"

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

echo "Installed nexdev-cli to $LAUNCHER_DEST"
