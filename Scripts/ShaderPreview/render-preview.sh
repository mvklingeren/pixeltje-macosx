#!/bin/zsh
# Renders offline previews of a GPU Program workflow; see main.swift for usage.
set -euo pipefail

project_root=${0:A:h:h:h}
engine=$project_root/Sources/PixeltjePipelineEngine
sources=(
  "$project_root/Scripts/ShaderPreview/main.swift"
  "$engine/PipelineMetalLibraries.swift"
  "$engine/PipelineMetalEasing.swift"
  "$engine/PipelineMetal3D.swift"
  "$engine/PipelineMetalTerrain.swift"
  "$engine/PipelineMetalPostFX.swift"
  "$engine/PipelineSystemFont.swift"
)
binary=${TMPDIR:-/tmp}/pixeltje-shader-preview/render-preview

rebuild=false
[[ -x $binary ]] || rebuild=true
for source in $sources; do [[ $source -nt $binary ]] && rebuild=true; done
if $rebuild; then
  mkdir -p ${binary:h}
  DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer} \
    xcrun swiftc -O $sources -o $binary
fi
exec $binary "$@"
