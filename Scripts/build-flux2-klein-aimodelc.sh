#!/bin/zsh
set -euo pipefail

if [[ ( $# -ne 3 && $# -ne 4 ) || "$1" != /* || "$2" != /* || -z "$3" ]]; then
  print -u2 "usage: $0 /absolute/source/FLUX.2-klein-4B /absolute/output/FLUX.2-klein-4B-h17g ARCHITECTURE [gpu|neural-engine|none]"
  exit 2
fi

source=${1:A}
output=${2:A}
architecture=$3
compute=${4:-gpu}
if [[ ! "$architecture" =~ '^[[:alnum:]]+$' || ! -d "$source" || -e "$output" || -L "$output" ]]; then
  print -u2 "error: invalid architecture/source or output already exists"
  exit 2
fi
if [[ "$compute" != gpu && "$compute" != neural-engine && "$compute" != none ]]; then
  print -u2 "error: compute preference must be gpu, neural-engine, or none"
  exit 2
fi
if [[ "$output" == "$source" || "$output" == "$source"/* || "$source" == "$output"/* ]]; then
  print -u2 "error: source and output must be separate directories"
  exit 2
fi
for name in Transformer TextEncoder VAEDecoder; do
  if [[ ! -s "$source/$name.aimodel/main.mlirb" || ! -s "$source/$name.aimodel/main.hash" ]]; then
    print -u2 "error: missing materialized source asset $name.aimodel"
    exit 2
  fi
done
for sidecar in metadata.json tokenizer/tokenizer.json tokenizer/tokenizer_config.json vae_bn_mean.npy vae_bn_var.npy; do
  if [[ ! -s "$source/$sidecar" ]]; then
    print -u2 "error: missing source sidecar $sidecar"
    exit 2
  fi
done

developer_dir=/Applications/Xcode-beta.app/Contents/Developer
if [[ ! -d "$developer_dir" || ! -x /usr/bin/xcrun ]]; then
  print -u2 "error: Xcode beta developer tools are not installed"
  exit 2
fi
mkdir -p "${output:h}"
staging=$(mktemp -d "${output}.staging.XXXXXX")
print "Building $architecture Core AI assets (preferred compute: $compute) in $staging"

for name in Transformer TextEncoder VAEDecoder; do
  DEVELOPER_DIR="$developer_dir" xcrun coreai-build compile "$source/$name.aimodel" \
    --output "$staging/$name.aimodelc" --platform macOS \
    --min-deployment-version 27.0 --preferred-compute "$compute" --architecture "$architecture"
  compiled="$staging/$name.aimodelc"
  if [[ ! -s "$compiled/main-$architecture.mlirb" || ! -d "$compiled/main-$architecture-delegates" || ! -s "$compiled/main.hash" ]]; then
    print -u2 "error: incomplete compiled asset: $compiled"
    exit 1
  fi
  source_hash=$(xxd -p -c 256 "$source/$name.aimodel/main.hash")
  recorded_hash=$(plutil -extract sourceHash raw -o - "$compiled/metadata.json")
  if [[ "${source_hash:l}" != "${recorded_hash:l}" ]]; then
    print -u2 "error: compiled $name does not identify the input source hash"
    exit 1
  fi
done

cp "$source/metadata.json" "$source/vae_bn_mean.npy" "$source/vae_bn_var.npy" "$staging/"
cp -R "$source/tokenizer" "$staging/tokenizer"
if [[ -e "$output" || -L "$output" ]]; then
  print -u2 "error: output appeared during compilation; preserving staging at $staging"
  exit 1
fi
mv "$staging" "$output"
print "Compiled package: $output"
print "The source export is unchanged. Explicitly relink graphs to this compiled package."
