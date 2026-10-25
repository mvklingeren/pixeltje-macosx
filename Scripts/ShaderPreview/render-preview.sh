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
  "$engine/PipelineMetalPhysics.swift"
  "$engine/PipelineSystemFont.swift"
  "$engine/PipelineSkinnedModel.swift"
)
ufbx=$project_root/Sources/CUFBX
binary=${TMPDIR:-/tmp}/pixeltje-shader-preview/render-preview

rebuild=false
[[ -x $binary ]] || rebuild=true
for source in $sources $ufbx/ufbx.c; do [[ $source -nt $binary ]] && rebuild=true; done
if $rebuild; then
  build=${binary:h}
  mkdir -p $build/CUFBX
  export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
  # The engine's FBX loader imports ufbx as the CUFBX module.
  print "module CUFBX { header \"$ufbx/include/ufbx.h\"\n export * }" \
    > $build/CUFBX/module.modulemap
  xcrun clang -O2 -c $ufbx/ufbx.c -I $ufbx/include -o $build/ufbx.o
  xcrun swiftc -O $sources -I $build/CUFBX $build/ufbx.o -o $binary
fi
exec $binary "$@"
