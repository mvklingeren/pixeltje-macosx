#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
configuration=${1:-release}
build_root="$project_root/.build"
scratch_root="$build_root/app-scratch"
bundle="$build_root/PixeltjeMacApp.app"

swift build \
  --package-path "$project_root" \
  --scratch-path "$scratch_root" \
  --disable-sandbox \
  --configuration "$configuration" \
  --product PixeltjeMacApp

binary_dir=$(swift build \
  --package-path "$project_root" \
  --scratch-path "$scratch_root" \
  --disable-sandbox \
  --configuration "$configuration" \
  --show-bin-path)

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/PixeltjeMacApp" "$bundle/Contents/MacOS/PixeltjeMacApp"
cp "$project_root/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$project_root/Sources/PixeltjeMacApp/Resources/AppIcon.icns" \
  "$bundle/Contents/Resources/AppIcon.icns"
cp -R "$binary_dir/PixeltjeMacApp_PixeltjeMacKit.bundle" \
  "$bundle/Contents/Resources/PixeltjeMacApp_PixeltjeMacKit.bundle"
cp -R "$project_root/Scripts/ComfyUI" \
  "$bundle/Contents/Resources/ComfyUISetup"
cp "$project_root/Sources/PixeltjeMacKit/Resources/ComfyUI/"*.tsv \
  "$bundle/Contents/Resources/ComfyUISetup/"

codesign \
  --force \
  --sign - \
  --entitlements "$project_root/Resources/PixeltjeMacApp.entitlements" \
  "$bundle"

echo "$bundle"
