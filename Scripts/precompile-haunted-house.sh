#!/bin/zsh
# Build the bundled Haunted House shader and its two expensive pipeline states.
set -euo pipefail

project_root=${0:A:h:h}
destination=${1:?usage: precompile-haunted-house.sh <Examples destination>}
scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/pixeltje-haunted-precompile.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$destination"

shader=$scratch/HauntedHouseProgram.resolved.metal
library=$destination/HauntedHouseProgram.metallib
archive=$destination/HauntedHouseProgram.binary.metallib
script=$scratch/HauntedHouseProgram.mtlp-json

"$project_root/Scripts/ShaderPreview/render-preview.sh" \
  "$project_root/Examples/shader-haunted-house-halloween.pixpipeline.json" \
  "$project_root/Scripts/ShaderPreview/haunted-house-street.views.json" \
  "$scratch" --node render --dump-source "$shader"

metal_tools=(/private/var/run/com.apple.security.cryptexd/mnt/*/Metal.xctoolchain/usr/bin/metal(N))
if (( ${#metal_tools} == 0 )); then
  print -u2 'The macOS 27 Metal toolchain is unavailable.'
  exit 1
fi
tools_dir=${metal_tools[1]:h}
# macOS 27's Apple GPU targets. The Metal 3 family also selects AMD targets,
# whose translator rejects this shader. A missing slice uses Metal IR instead.
archive_flags=(
  -arch applegpu_g12p
  -arch applegpu_g13p -arch applegpu_g13g -arch applegpu_g13s -arch applegpu_g13d
  -arch applegpu_g14p -arch applegpu_g14g -arch applegpu_g14s -arch applegpu_g14d
  -arch applegpu_g15p -arch applegpu_g15g -arch applegpu_g15s -arch applegpu_g15d
  -arch applegpu_g16p -arch applegpu_g16g -arch applegpu_g16s
  -arch applegpu_g17p -arch applegpu_g17g -arch applegpu_g17s
)
if [[ -n ${PIXELTJE_METAL_ARCH_FLAGS:-} ]]; then
  archive_flags=(${=PIXELTJE_METAL_ARCH_FLAGS})
fi
source_hash=$(/usr/bin/shasum -a 256 "$shader" | /usr/bin/awk '{ print $1 }')
cache_key=$(print -r -- "$source_hash|$tools_dir|${(j: :)archive_flags}" \
  | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }')
cache="$project_root/.build/haunted-metal-cache/$cache_key"
if [[ -f "$cache/HauntedHouseProgram.metallib" \
  && -f "$cache/HauntedHouseProgram.binary.metallib" ]]; then
  cp "$cache/HauntedHouseProgram.metallib" "$library"
  cp "$cache/HauntedHouseProgram.binary.metallib" "$archive"
  print -r -- "$source_hash" > "$destination/HauntedHouseProgram.source.sha256"
  exit 0
fi

"$tools_dir/metal" -c -std=metal3.2 -target air64-apple-macos27.0 \
  -fmodules-cache-path="$scratch/module-cache" "$shader" \
  -o "$scratch/HauntedHouseProgram.air"
"$tools_dir/metallib" "$scratch/HauntedHouseProgram.air" -o "$library"

cat > "$script" <<'JSON'
{
  "libraries": { "paths": [
    { "label": "HauntedHouse", "path": "HauntedHouseProgram.metallib" }
  ] },
  "pipelines": {
    "compute_pipelines": [
      { "compute_function": "alias:HauntedHouse#initializeRange" }
    ],
    "render_pipelines": [
      {
        "vertex_function": "alias:HauntedHouse#fullscreenVertex",
        "fragment_function": "alias:HauntedHouse#rangeFragment",
        "color_attachments": [ { "pixel_format": "RGBA16Float" } ]
      }
    ]
  }
}
JSON

(cd "$destination" && "$tools_dir/metal-tt" "$library" "$script" \
  -target air64-apple-macos27.0 $archive_flags -o "$archive")
print -r -- "$source_hash" > "$destination/HauntedHouseProgram.source.sha256"
mkdir -p "$cache"
cp "$library" "$archive" "$cache/"
