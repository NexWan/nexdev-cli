#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(node -p "require('./package.json').version")}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-NexWan/nexdev-cli}}"
TARGET_NAME="${TARGET_NAME:-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
ARCHIVE_NAME="nexdev-cli-${VERSION}-${TARGET_NAME}"
STAGE_DIR="$OUT_DIR/stage/$ARCHIVE_NAME"
RUNTIME_DIR="$STAGE_DIR/lib/nexdev-cli"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin" "$RUNTIME_DIR"

zig build --fetch
zig build -Doptimize=ReleaseSafe

cp "$ROOT_DIR/zig-out/bin/nexdev_cli" "$STAGE_DIR/bin/nexdev_cli"
chmod 755 "$STAGE_DIR/bin/nexdev_cli"

cp -R "$ROOT_DIR/agent" "$RUNTIME_DIR/agent"
cp "$ROOT_DIR/package.json" "$ROOT_DIR/package-lock.json" "$RUNTIME_DIR/"
npm ci --omit=dev --prefix "$RUNTIME_DIR"

cp "$ROOT_DIR/packaging/install.sh" "$STAGE_DIR/install.sh"
chmod 755 "$STAGE_DIR/install.sh"

cat > "$STAGE_DIR/README.txt" <<EOF
nexdev-cli ${VERSION}

Download this archive from GitHub:
  curl -L -o ${ARCHIVE_NAME}.tar.gz \\
    https://github.com/${REPOSITORY}/releases/download/${VERSION}/${ARCHIVE_NAME}.tar.gz

  wget -O ${ARCHIVE_NAME}.tar.gz \\
    https://github.com/${REPOSITORY}/releases/download/${VERSION}/${ARCHIVE_NAME}.tar.gz

Install:
  tar -xzf ${ARCHIVE_NAME}.tar.gz
  cd ${ARCHIVE_NAME}
  ./install.sh

Override install locations:
  PREFIX="\$HOME/.local" ./install.sh

Runtime requirements:
  - Node.js 22.6 or newer must be available on PATH.
  - The TypeScript/Codex runtime dependencies are bundled in lib/nexdev-cli.
EOF

mkdir -p "$OUT_DIR"
tar -czf "$OUT_DIR/$ARCHIVE_NAME.tar.gz" -C "$OUT_DIR/stage" "$ARCHIVE_NAME"

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$OUT_DIR/$ARCHIVE_NAME.tar.gz" > "$OUT_DIR/$ARCHIVE_NAME.tar.gz.sha256"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT_DIR/$ARCHIVE_NAME.tar.gz" > "$OUT_DIR/$ARCHIVE_NAME.tar.gz.sha256"
fi

echo "$OUT_DIR/$ARCHIVE_NAME.tar.gz"
