# SourceKit-LSP for Codex

This repository exposes SourceKit-LSP to local Codex clients through the
third-party `anvyxhq/swift-mcp-server` MCP bridge. The bridge source and build
artifacts are kept in the ignored `vendor/` directory. `REVISION` pins the
reviewable upstream commit used by `setup.sh`, and `Package.resolved` pins its
transitive Swift package dependencies. Project-maintained compatibility fixes
live in `patches/` and are applied reproducibly before each build.

Install or refresh the bridge from the repository root:

```sh
.codex/sourcekit-mcp/setup.sh
```

Restart the ChatGPT desktop app, Codex CLI, or Codex IDE extension after the
first installation or a configuration change. Use `/mcp` or `codex mcp list`
to check the connection.

The active `swift_pixeltje_macosx` server indexes this standalone SwiftPM
repository. The project configuration finds the Git checkout root at launch,
and the launcher defaults to that root, so moving or cloning the repository
does not require editing a machine-specific path. Start Codex from inside the
checkout so the configuration can resolve the root.

Only semantic read tools are allowlisted. The bridge also offers formatting,
rename, and code-action tools that can write to the workspace; add those tools
to `.codex/config.toml` only after reviewing the bridge and the desired
approval policy.

Set `PIXELTJE_SOURCEKIT_DEVELOPER_DIR` to select a different Xcode developer
directory. Otherwise the launcher prefers stable Xcode, then Xcode beta, then
the currently selected command-line toolchain.
