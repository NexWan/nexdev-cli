# nexdev-cli

Terminal UI for running NexDev agent conversations through the bundled
TypeScript Codex runtime.

## Install

Install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/NexWan/nexdev-cli/main/scripts/install.sh | bash
```

Install a specific release:

```sh
curl -fsSL https://raw.githubusercontent.com/NexWan/nexdev-cli/main/scripts/install.sh | VERSION="v0.1.0" bash
```

The bootstrap installer detects your OS and CPU architecture, downloads the
matching release archive, verifies the checksum when available, and runs the
archive-local installer.

## Requirements

- Linux, macOS, or Windows with Bash available.
- x64 or arm64 CPU architecture.
- Node.js 22.6 or newer on `PATH`.
- `curl` or `wget`, plus `tar`.

On Windows, run the command from Git Bash, MSYS2, Cygwin, or WSL. The Bash
installer is not a native PowerShell installer.

## Install Locations

Default install locations are per-user and do not require `sudo`.

| OS | Launcher directory | Runtime directory |
| --- | --- | --- |
| Linux | `$HOME/.local/bin` | `${XDG_DATA_HOME:-$HOME/.local/share}/nexdev-cli` |
| macOS | `$HOME/.local/bin` | `$HOME/Library/Application Support/nexdev-cli` |
| Windows | `%LOCALAPPDATA%\Programs\nexdev-cli\bin` | `%LOCALAPPDATA%\nexdev-cli` |

The installer does not edit shell startup files. Add the printed launcher
directory to `PATH` if `nexdev-cli` is not available after installation.

Override the install prefix:

```sh
curl -fsSL https://raw.githubusercontent.com/NexWan/nexdev-cli/main/scripts/install.sh | PREFIX="$HOME/.local" bash
```

Override individual directories:

```sh
curl -fsSL https://raw.githubusercontent.com/NexWan/nexdev-cli/main/scripts/install.sh | \
  BIN_DIR="$HOME/bin" LIB_DIR="$HOME/.local/share/nexdev-cli" bash
```

## Manual Release Install

Download a release archive directly when you need to inspect the package before
installing:

```sh
VERSION="v0.1.0"
TARGET="linux-x64"
curl -L -o "nexdev-cli-${VERSION}-${TARGET}.tar.gz" \
  "https://github.com/NexWan/nexdev-cli/releases/download/${VERSION}/nexdev-cli-${VERSION}-${TARGET}.tar.gz"
tar -xzf "nexdev-cli-${VERSION}-${TARGET}.tar.gz"
cd "nexdev-cli-${VERSION}-${TARGET}"
./install.sh
```

Supported release targets are `linux-x64`, `linux-arm64`, `macos-x64`,
`macos-arm64`, `windows-x64`, and `windows-arm64` when those assets are
published for a release.

## Development

Contributor requirements:

- Zig 0.16.0.
- Node.js 22.6 or newer.
- npm.

Build and test locally:

```sh
npm ci
npm run typecheck
zig build --fetch
zig build test
```
