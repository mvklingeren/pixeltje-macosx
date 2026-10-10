#!/bin/sh
# Decode and validate every Base Test Set workflow without loading a model or a GUI.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/pixeltje-base-test-set-validation.XXXXXX")
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM

cat > "$scratch_dir/main.swift" <<'SWIFT'
import Foundation
import PixeltjePipelineDomain

var failed = false
for argument in CommandLine.arguments.dropFirst() {
  let url = URL(fileURLWithPath: argument)
  do {
    let document = try PipelineJSON.decode(Data(contentsOf: url))
    let report = PipelineGraphValidator.validate(
      document, registry: .coreAIV1, engineVersion: 1)
    let order = try PipelineGraphTopology.orderedNodeIDs(in: document)
    print("\(url.lastPathComponent): \(document.nodes.count) nodes, \(document.connections.count) links, \(report.errors.count) errors, \(report.warnings.count) warnings, \(order.count) sorted")
    for diagnostic in report.diagnostics {
      print("  \(diagnostic.severity.rawValue) \(diagnostic.code.rawValue): \(diagnostic.message)")
    }
    if !report.isValid || !report.warnings.isEmpty { failed = true }
  } catch {
    print("\(url.lastPathComponent): \(error)")
    failed = true
  }
}
if failed { exit(1) }
SWIFT

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swiftc -swift-version 6 \
  -module-cache-path "$scratch_dir/module-cache" \
  -emit-library -emit-module -module-name PixeltjePipelineDomain \
  "$project_root"/Sources/PixeltjePipelineDomain/*.swift \
  -emit-module-path "$scratch_dir/PixeltjePipelineDomain.swiftmodule" \
  -o "$scratch_dir/libPixeltjePipelineDomain.dylib"

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swiftc -swift-version 6 \
  -module-cache-path "$scratch_dir/module-cache" \
  -I "$scratch_dir" -L "$scratch_dir" -lPixeltjePipelineDomain \
  "$project_root"/Sources/PixeltjePipelineEngine/BuiltInPipelineNodes*.swift \
  "$scratch_dir/main.swift" -o "$scratch_dir/validate"

DYLD_LIBRARY_PATH="$scratch_dir" "$scratch_dir/validate" \
  "$project_root"/Examples/BaseTestSet/*.pixpipeline.json

python3 - "$project_root/Examples/BaseTestSet" <<'PY'
import json
import struct
import subprocess
import sys
from pathlib import Path

folder = Path(sys.argv[1])
card = folder / 'test-card.png'
clip = folder / 'moving-test-card.mp4'
tone = folder / 'two-tone.wav'
with card.open('rb') as source:
    header = source.read(24)
assert header[:8] == b'\x89PNG\r\n\x1a\n'
assert struct.unpack('>II', header[16:24]) == (512, 384)
probe = json.loads(subprocess.check_output([
    'ffprobe', '-v', 'error', '-show_entries',
    'format=duration:stream=codec_name,codec_type,width,height,r_frame_rate,nb_frames',
    '-of', 'json', str(clip)], text=True))
video = next(stream for stream in probe['streams'] if stream['codec_type'] == 'video')
audio = next(stream for stream in probe['streams'] if stream['codec_type'] == 'audio')
assert (video['width'], video['height']) == (320, 180)
assert video['r_frame_rate'] == '12/1' and int(video['nb_frames']) == 24
assert audio['codec_name'] == 'aac'
assert abs(float(probe['format']['duration']) - 2.0) < 0.01
import wave
with wave.open(str(tone), 'rb') as source:
    assert (source.getnchannels(), source.getsampwidth(),
            source.getframerate(), source.getnframes()) == (1, 2, 48000, 96000)
print('Media: 512 × 384 PNG; 320 × 180, 24-frame H.264/AAC video; 2-second mono PCM WAV')
PY

echo 'Structure and input media only: no workflow nodes ran, and no output was produced or compared.'
