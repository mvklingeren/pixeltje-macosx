#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 VERSION" >&2
    exit 2
fi

new_version=$1
if ! printf '%s\n' "$new_version" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}$'; then
    echo "error: version must contain two or three dot-separated non-negative integers" >&2
    exit 2
fi

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "error: run this command from inside the Pixeltje Mac repository" >&2
    exit 1
}

info_plist="$repository_root/Resources/Info.plist"
mcp_source="$repository_root/Sources/PixeltjeMCP/PixeltjeMCPServer.swift"
app_source="$repository_root/Sources/PixeltjeMacKit/Application/RunApplication.swift"

for required_file in "$info_plist" "$mcp_source" "$app_source"; do
    if [ ! -f "$required_file" ]; then
        echo "error: required version file is missing: $required_file" >&2
        exit 1
    fi
done

old_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
mcp_old='"serverInfo": ["name": "Pixeltje Mac", "version": "'"$old_version"'"]'
app_old='.applicationVersion: "'"$old_version"'",'

if [ "$(grep -F -c "$mcp_old" "$mcp_source")" -ne 1 ]; then
    echo "error: MCP server version is missing or inconsistent with Info.plist ($old_version)" >&2
    exit 1
fi

if [ "$(grep -F -c "$app_old" "$app_source")" -ne 1 ]; then
    echo "error: About panel version is missing or inconsistent with Info.plist ($old_version)" >&2
    exit 1
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/pixeltje-version.XXXXXX")
temporary_info="$temporary_directory/Info.plist"
temporary_mcp="$temporary_directory/PixeltjeMCPServer.swift"
temporary_app="$temporary_directory/RunApplication.swift"

cleanup() {
    rm -f "$temporary_info" "$temporary_mcp" "$temporary_app"
    rmdir "$temporary_directory" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

cp "$info_plist" "$temporary_info"
cp "$mcp_source" "$temporary_mcp"
cp "$app_source" "$temporary_app"

OLD_VERSION="$old_version" NEW_VERSION="$new_version" perl -0pi -e '
    s{\Q<key>CFBundleShortVersionString</key>\E(\s*)\Q<string>$ENV{OLD_VERSION}</string>\E}{<key>CFBundleShortVersionString</key>$1<string>$ENV{NEW_VERSION}</string>}g
' "$temporary_info"
OLD_VERSION="$old_version" NEW_VERSION="$new_version" perl -0pi -e '
    s/\Q"serverInfo": ["name": "Pixeltje Mac", "version": "$ENV{OLD_VERSION}"]\E/"serverInfo": ["name": "Pixeltje Mac", "version": "$ENV{NEW_VERSION}"]/g
' "$temporary_mcp"
OLD_VERSION="$old_version" NEW_VERSION="$new_version" perl -0pi -e '
    s/\Q.applicationVersion: "$ENV{OLD_VERSION}",\E/.applicationVersion: "$ENV{NEW_VERSION}",/g
' "$temporary_app"

plutil -lint "$temporary_info" >/dev/null
updated_plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$temporary_info")
mcp_new='"serverInfo": ["name": "Pixeltje Mac", "version": "'"$new_version"'"]'
app_new='.applicationVersion: "'"$new_version"'",'

if [ "$updated_plist_version" != "$new_version" ]; then
    echo "error: failed to update CFBundleShortVersionString" >&2
    exit 1
fi

if [ "$(grep -F -c "$mcp_new" "$temporary_mcp")" -ne 1 ]; then
    echo "error: failed to update the MCP server version" >&2
    exit 1
fi

if [ "$(grep -F -c "$app_new" "$temporary_app")" -ne 1 ]; then
    echo "error: failed to update the About panel version" >&2
    exit 1
fi

cp "$temporary_info" "$info_plist"
cp "$temporary_mcp" "$mcp_source"
cp "$temporary_app" "$app_source"

printf 'Version: %s -> %s\n' "$old_version" "$new_version"
printf 'Updated: %s\n' "$info_plist"
printf 'Updated: %s\n' "$mcp_source"
printf 'Updated: %s\n' "$app_source"
