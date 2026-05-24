# Release and Install

Releases are published by the `Release` GitHub Actions workflow.

## Publish a Version

Create and push a semantic version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow builds native Linux, macOS, and Windows archives, bundles the
TypeScript Codex runtime dependencies, and publishes the artifacts to a GitHub
Release.

You can also run the workflow manually from GitHub Actions and provide a
version label such as `v0.1.0`.

## Install With One Command

Install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/NexWan/nexdev-cli/main/scripts/install.sh | bash
```

Install a specific release:

```sh
curl -fsSL https://raw.githubusercontent.com/NexWan/nexdev-cli/main/scripts/install.sh | VERSION="v0.1.0" bash
```

The bootstrap installer detects Linux, macOS, or Windows, maps the current
architecture to `x64` or `arm64`, downloads the matching release archive, and
runs the archive-local installer.

## Install From a Release Archive

Download the archive for your OS, unpack it, then run:

```sh
tar -xzf nexdev-cli-v0.1.0-linux-x64.tar.gz
cd nexdev-cli-v0.1.0-linux-x64
./install.sh
```

The GitHub Release page includes copyable `curl` and `wget` commands. The
general form is:

```sh
VERSION="v0.1.0"
TARGET="linux-x64"
curl -L -o "nexdev-cli-${VERSION}-${TARGET}.tar.gz" \
  "https://github.com/NexWan/nexdev-cli/releases/download/${VERSION}/nexdev-cli-${VERSION}-${TARGET}.tar.gz"
```

Or with `wget`:

```sh
VERSION="v0.1.0"
TARGET="linux-x64"
wget -O "nexdev-cli-${VERSION}-${TARGET}.tar.gz" \
  "https://github.com/NexWan/nexdev-cli/releases/download/${VERSION}/nexdev-cli-${VERSION}-${TARGET}.tar.gz"
```

By default, the installer writes:

| OS | Launcher directory | Runtime directory |
| --- | --- | --- |
| Linux | `$HOME/.local/bin` | `${XDG_DATA_HOME:-$HOME/.local/share}/nexdev-cli` |
| macOS | `$HOME/.local/bin` | `$HOME/Library/Application Support/nexdev-cli` |
| Windows | `%LOCALAPPDATA%\Programs\nexdev-cli\bin` | `%LOCALAPPDATA%\nexdev-cli` |

Use a different prefix with:

```sh
PREFIX="$HOME/.local" ./install.sh
```

Requirements:

- Linux, macOS, or Windows with Bash available.
- x64 or arm64 release asset for your OS.
- Node.js 22.6 or newer on `PATH`.
- `curl` or `wget`, plus `tar`.

The installer does not edit shell startup files. Add the printed launcher
directory to `PATH` if `nexdev-cli` is not available after installation.
