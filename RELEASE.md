# Release and Install

Releases are published by the `Release` GitHub Actions workflow.

## Publish a Version

Create and push a semantic version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow builds native Linux and macOS archives, bundles the TypeScript
Codex runtime dependencies, and publishes the artifacts to a GitHub Release.

You can also run the workflow manually from GitHub Actions and provide a
version label such as `v0.1.0`.

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

The installer writes:

- `nexdev-cli` launcher to `/usr/local/bin`
- Zig console binary to `/usr/local/lib/nexdev-cli/bin`
- TypeScript runtime and production `node_modules` to `/usr/local/lib/nexdev-cli`

Use a different prefix with:

```sh
PREFIX="$HOME/.local" ./install.sh
```

Node.js 22.6 or newer must be available on `PATH`.
