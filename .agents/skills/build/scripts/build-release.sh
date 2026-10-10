#!/bin/sh

set -eu

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "error: run this command from inside the Pixeltje Mac repository" >&2
    exit 1
}

developer_directory=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
if [ ! -d "$developer_directory" ]; then
    echo "error: Xcode beta developer directory is unavailable: $developer_directory" >&2
    exit 1
fi

info_plist="$repository_root/Resources/Info.plist"
packager="$repository_root/scripts/build-app.sh"
app_bundle="$repository_root/.build/PixeltjeMacApp.app"
destination_directory=${1:-"${HOME}/Desktop/pixeltje-macosx-builds"}

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
minimum_system=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")
if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}$'; then
    echo "error: unsafe or invalid release version in Info.plist: $version" >&2
    exit 1
fi

DEVELOPER_DIR="$developer_directory" "$packager" release

codesign --verify --deep --strict --verbose=2 "$app_bundle"
architectures=$(lipo -archs "$app_bundle/Contents/MacOS/PixeltjeMacApp")
case "$architectures" in
    arm64|x86_64) architecture=$architectures ;;
    *) architecture=universal ;;
esac

mkdir -p "$destination_directory"
archive_stem="PixeltjeMacApp-${version}-macOS${minimum_system}-${architecture}"
archive_path="$destination_directory/${archive_stem}.zip"
if [ -e "$archive_path" ]; then
    timestamp=$(date '+%Y-%m-%d_%H%M%S')
    archive_path="$destination_directory/${archive_stem}-${timestamp}.zip"
fi
if [ -e "$archive_path" ]; then
    archive_path="$destination_directory/${archive_stem}-$(date '+%Y-%m-%d_%H%M%S')-$$.zip"
fi

temporary_directory=$(mktemp -d "$destination_directory/.pixeltje-build.XXXXXX")
partial_archive="$temporary_directory/${archive_stem}.zip"

cleanup() {
    rm -f "$partial_archive"
    rmdir "$temporary_directory" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

ditto -c -k --keepParent "$app_bundle" "$partial_archive"
unzip -tq "$partial_archive"
mv "$partial_archive" "$archive_path"
rmdir "$temporary_directory"
trap - EXIT HUP INT TERM

archive_size=$(stat -f '%z' "$archive_path")
archive_digest=$(shasum -a 256 "$archive_path" | awk '{print $1}')

printf 'Build: %s\n' "$archive_path"
printf 'Version: %s\n' "$version"
printf 'Architecture: %s\n' "$architectures"
printf 'Minimum macOS: %s\n' "$minimum_system"
printf 'Size: %s bytes\n' "$archive_size"
printf 'SHA-256: %s\n' "$archive_digest"
