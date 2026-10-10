#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
configuration=${1:-release}
bundle="$project_root/.build/Pixeltje Pipeline.app"

for product in PixeltjePipeline pixeltje-pipeline-agent pixeltje-pipeline-link-text; do
  swift build \
    --package-path "$project_root" \
    --disable-sandbox \
    --configuration "$configuration" \
    --product "$product"
done

binary_dir=$(swift build \
  --package-path "$project_root" \
  --disable-sandbox \
  --configuration "$configuration" \
  --show-bin-path)

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/PixeltjePipeline" "$bundle/Contents/MacOS/PixeltjePipeline"
cp "$binary_dir/pixeltje-pipeline-agent" \
  "$bundle/Contents/MacOS/pixeltje-pipeline-agent"
cp "$binary_dir/pixeltje-pipeline-link-text" \
  "$bundle/Contents/MacOS/pixeltje-pipeline-link-text"
cp "$project_root/Resources/PixeltjePipeline-Info.plist" "$bundle/Contents/Info.plist"
cp -R "$project_root/Examples" "$bundle/Contents/Resources/Examples"
model_setup="$bundle/Contents/Resources/ModelSetup"
mkdir -p "$model_setup"
for script in setup-flux2-klein-9b.command setup-flux2-klein-9b-coreai.py \
  export-flux2-klein-9b-fp8.py export-flux2-klein-9b-qwen3-fp8.py \
  export-flux2-klein-vae.py assemble-flux2-klein-9b-package.py; do
  cp "$project_root/Scripts/$script" "$model_setup/$script"
done
cp "$project_root/Documentation/UserGuide/Model-Setup-Guide.html" \
  "$model_setup/Model-Setup-Guide.html"
chmod 755 "$model_setup/setup-flux2-klein-9b.command"
for bundle_name in swift-crypto_Crypto.bundle swift-transformers_Hub.bundle; do
  resource_bundle="$binary_dir/$bundle_name"
  [[ -d "$resource_bundle" ]] || continue
  cp -R "$resource_bundle" "$bundle/Contents/Resources/"
done
codesign --force --sign - "$bundle/Contents/MacOS/pixeltje-pipeline-agent"
codesign --force --sign - "$bundle/Contents/MacOS/pixeltje-pipeline-link-text"
codesign --force --sign - "$bundle"
echo "$bundle"
