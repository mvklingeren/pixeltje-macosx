#!/bin/bash
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/bin/bash "$script_dir/download-workflow.sh" flux2-klein-image-edit-distilled --download "$@"
status=$?
if [[ -t 0 && $# -eq 0 ]]; then
  read -r -p 'Press Return to close this window...' answer
fi
exit "$status"
