#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:?VERSION is required}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-NexWan/nexdev-cli}}"
RELEASE_NOTES_PATH="${RELEASE_NOTES_PATH:-dist/release-notes.md}"

mkdir -p "$(dirname "$RELEASE_NOTES_PATH")"

cat > "$RELEASE_NOTES_PATH" <<EOF
## Install

Install the latest release with:

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/${REPOSITORY}/main/scripts/install.sh | bash
\`\`\`

Install this exact release with:

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/${REPOSITORY}/main/scripts/install.sh | VERSION="${VERSION}" bash
\`\`\`

The bootstrap installer detects Linux, macOS, or Windows and downloads the
matching release archive for x64 or arm64.

### Manual Download

Choose the asset suffix for your system from this release, for example
\`linux-x64\`, \`macos-arm64\`, \`macos-x64\`, or \`windows-x64\`.

#### curl

\`\`\`sh
VERSION="${VERSION}"
TARGET="linux-x64"
curl -L -o "nexdev-cli-\${VERSION}-\${TARGET}.tar.gz" \\
  "https://github.com/${REPOSITORY}/releases/download/\${VERSION}/nexdev-cli-\${VERSION}-\${TARGET}.tar.gz"
tar -xzf "nexdev-cli-\${VERSION}-\${TARGET}.tar.gz"
cd "nexdev-cli-\${VERSION}-\${TARGET}"
PREFIX="\$HOME/.local" ./install.sh
\`\`\`

#### wget

\`\`\`sh
VERSION="${VERSION}"
TARGET="linux-x64"
wget -O "nexdev-cli-\${VERSION}-\${TARGET}.tar.gz" \\
  "https://github.com/${REPOSITORY}/releases/download/\${VERSION}/nexdev-cli-\${VERSION}-\${TARGET}.tar.gz"
tar -xzf "nexdev-cli-\${VERSION}-\${TARGET}.tar.gz"
cd "nexdev-cli-\${VERSION}-\${TARGET}"
PREFIX="\$HOME/.local" ./install.sh
\`\`\`

Requirements:

- Linux, macOS, or Windows with Bash available.
- x64 or arm64 release asset for your OS.
- Node.js 22.6 or newer on \`PATH\`.
- \`curl\` or \`wget\`, plus \`tar\`.

The archive bundles the TypeScript/Codex runtime dependencies used by the Zig
console. The installer does not edit shell startup files; add the printed
binary directory to \`PATH\` if needed.
EOF

echo "$RELEASE_NOTES_PATH"
