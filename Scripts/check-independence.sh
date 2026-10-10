#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
scan_roots=(
  "$project_root/Package.swift"
  "$project_root/Sources"
  "$project_root/Tests"
  "$project_root/Resources"
)

forbidden='LibRaw|rsraw|@_cdecl|dlopen\(|Process\(executableURL'

# An `if <missing command>` is false, so a scanner that is not installed would
# report a clean boundary without having read anything. Pick one explicitly.
if command -v rg >/dev/null 2>&1; then
  scan() { rg -n "$1" "${scan_roots[@]}" }
elif command -v grep >/dev/null 2>&1; then
  scan() { grep -rnE "$1" "${scan_roots[@]}" }
else
  echo "Neither rg nor grep is available; cannot check the boundary." >&2
  exit 1
fi

if scan "$forbidden"; then
  echo "Forbidden dependency found." >&2
  exit 1
fi

if scan '(^|["( ])\.\./'; then
  echo "Parent-directory source or resource reference found." >&2
  exit 1
fi

if find "$project_root" -type l -not -path '*/.build/*' | grep -q .; then
  echo "Symlinks are not allowed in the standalone project." >&2
  exit 1
fi

echo "PixeltjeMacApp dependency boundary is clean."
