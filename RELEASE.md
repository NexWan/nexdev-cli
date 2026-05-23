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
./install.sh
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
