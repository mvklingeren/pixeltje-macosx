#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h:h}"
binary="$script_dir/vendor/swift-mcp-server/.build/release/swift-mcp-server"
workspace_name="${1:-.}"

if [[ "$workspace_name" == /* ]]; then
  workspace="$workspace_name"
else
  workspace="$project_root/$workspace_name"
fi

if [[ ! -x "$binary" ]]; then
  print -u2 "Swift MCP bridge is not installed. Run $script_dir/setup.sh"
  exit 1
fi

if [[ ! -f "$workspace/Package.swift" ]]; then
  print -u2 "SwiftPM workspace not found at $workspace"
  exit 1
fi

developer_dir="${PIXELTJE_SOURCEKIT_DEVELOPER_DIR:-}"
if [[ -z "$developer_dir" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    developer_dir=/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    developer_dir=/Applications/Xcode-beta.app/Contents/Developer
  fi
fi

if [[ -n "$developer_dir" ]]; then
  export DEVELOPER_DIR="$developer_dir"
  sourcekit_lsp="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
else
  sourcekit_lsp="$(xcrun --find sourcekit-lsp)"
fi

if [[ ! -x "$sourcekit_lsp" ]]; then
  print -u2 "sourcekit-lsp not found at $sourcekit_lsp"
  exit 1
fi

export SOURCEKIT_LSP_PATH="$sourcekit_lsp"
exec "$binary" --transport stdio --workspace "$workspace"
