#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source_dir="$script_dir/vendor/swift-mcp-server"
patch_dir="$script_dir/patches"
revision="$(tr -d '[:space:]' < "$script_dir/REVISION")"
repository="https://github.com/anvyxhq/swift-mcp-server.git"

if [[ ${#revision} -ne 40 || "$revision" == *[^0-9a-f]* ]]; then
  print -u2 "Invalid pinned revision in $script_dir/REVISION"
  exit 1
fi

patch_files=("$patch_dir"/*.patch(N))

if [[ -d "$source_dir/.git" ]]; then
  # Remove only this setup's known patches before checking for user changes.
  for patch_file in $patch_files; do
    if git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
      git -C "$source_dir" apply --reverse "$patch_file"
    fi
  done

  if ! git -C "$source_dir" diff --quiet || \
     ! git -C "$source_dir" diff --cached --quiet; then
    print -u2 "Refusing to replace modified bridge sources at $source_dir"
    exit 1
  fi
else
  mkdir -p "${source_dir:h}"
  git clone --filter=blob:none --no-checkout "$repository" "$source_dir"
fi

git -C "$source_dir" fetch --depth 1 origin "$revision"
git -C "$source_dir" checkout --detach "$revision"
cp "$script_dir/Package.resolved" "$source_dir/Package.resolved"

for patch_file in $patch_files; do
  git -C "$source_dir" apply --check "$patch_file"
  git -C "$source_dir" apply "$patch_file"
done

developer_dir="${PIXELTJE_SOURCEKIT_DEVELOPER_DIR:-}"
if [[ -z "$developer_dir" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    developer_dir=/Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    developer_dir=/Applications/Xcode-beta.app/Contents/Developer
  fi
fi

if [[ -n "$developer_dir" ]]; then
  DEVELOPER_DIR="$developer_dir" swift build \
    --package-path "$source_dir" \
    --disable-automatic-resolution \
    --configuration release
else
  swift build \
    --package-path "$source_dir" \
    --disable-automatic-resolution \
    --configuration release
fi

binary="$source_dir/.build/release/swift-mcp-server"
if [[ ! -x "$binary" ]]; then
  print -u2 "Build completed without producing $binary"
  exit 1
fi

print "Installed pinned Swift MCP bridge at $binary"
