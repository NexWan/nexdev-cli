#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:?VERSION is required}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-NexWan/nexdev-cli}}"
RELEASE_NOTES_PATH="${RELEASE_NOTES_PATH:-dist/release-notes.md}"

mkdir -p "$(dirname "$RELEASE_NOTES_PATH")"

cat > "$RELEASE_NOTES_PATH" <<EOF
## Install

Choose the asset suffix for your system from this release, for example
\`linux-x64\`, \`macos-arm64\`, or \`macos-x64\`.

### curl

\`\`\`sh
VERSION="${VERSION}"
TARGET="linux-x64"
curl -L -o "nexdev-cli-\${VERSION}-\${TARGET}.tar.gz" \\
  "https://github.com/${REPOSITORY}/releases/download/\${VERSION}/nexdev-cli-\${VERSION}-\${TARGET}.tar.gz"
tar -xzf "nexdev-cli-\${VERSION}-\${TARGET}.tar.gz"
cd "nexdev-cli-\${VERSION}-\${TARGET}"
PREFIX="\$HOME/.local" ./install.sh
\`\`\`

### wget

\`\`\`sh
VERSION="${VERSION}"
TARGET="linux-x64"
wget -O "nexdev-cli-\${VERSION}-\${TARGET}.tar.gz" \\
  "https://github.com/${REPOSITORY}/releases/download/\${VERSION}/nexdev-cli-\${VERSION}-\${TARGET}.tar.gz"
tar -xzf "nexdev-cli-\${VERSION}-\${TARGET}.tar.gz"
cd "nexdev-cli-\${VERSION}-\${TARGET}"
PREFIX="\$HOME/.local" ./install.sh
\`\`\`

Node.js 22.6 or newer must be available on \`PATH\`. The archive bundles the
TypeScript/Codex runtime dependencies used by the Zig console.
EOF

echo "$RELEASE_NOTES_PATH"
