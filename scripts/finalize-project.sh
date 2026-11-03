#!/bin/bash
# XcodeGen emits PBX syntax; finalize it with Apple's JSON project converter.
set -euo pipefail
cd "$(dirname "$0")/.."
project="HomeClaw.xcodeproj"

supports_conversion() {
    local version major minor
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/../Info.plist" 2>/dev/null) || return 1
    IFS=. read -r major minor _ <<< "$version"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    (( major > 27 || (major == 27 && minor >= 2) ))
}

converter="${XCODE_PROJECT_CONVERTER_DIR:-${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}}"
if ! supports_conversion "$converter"; then
    converter=""
    if [[ -z "${XCODE_PROJECT_CONVERTER_DIR:-}" ]]; then
        for app in /Applications/Xcode*.app; do
            [[ -d "$app" ]] || continue
            if supports_conversion "$app/Contents/Developer"; then
                converter="$app/Contents/Developer"
                break
            fi
        done
    fi
fi
if [[ -z "$converter" ]]; then
    echo "error: JSON generation requires Xcode 27.2 or later. Set XCODE_PROJECT_CONVERTER_DIR to its Contents/Developer directory." >&2
    exit 1
fi
# Run before XcodeGen writes anything, preserving existing JSON on preflight failure.
if [[ "${1:-}" == "--check" ]]; then
    exit 0
fi
if [[ -f "$project/project.xcproj" && ! -f "$project/project.pbxproj" ]]; then
    exit 0
fi
[[ -f "$project/project.pbxproj" ]] || {
    echo "error: Missing generated $project/project.pbxproj." >&2
    exit 1
}

# Retain both inputs outside the bundle while Xcode requires a single definition.
backup=$(mktemp -d "${TMPDIR:-/tmp}/HomeClaw-project-format.XXXXXX")
cp -p "$project/project.pbxproj" "$backup/original.pbxproj"
restore_previous_project() {
    local status=$?
    if (( status != 0 )) && [[ -n "$backup" ]]; then
        for definition in project.xcproj project.pbxproj; do
            if [[ -e "$project/$definition" ]]; then
                mv "$project/$definition" "$backup/failed-$definition"
            fi
        done
        if [[ -f "$backup/project.xcproj" ]]; then
            mv "$backup/project.xcproj" "$project/project.xcproj"
        else
            cp -p "$backup/original.pbxproj" "$project/project.pbxproj"
        fi
        echo "error: Restored the previous project. Failed output retained at $backup" >&2
    fi
}
trap restore_previous_project EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -f "$project/project.xcproj" ]]; then
    mv "$project/project.xcproj" "$backup/project.xcproj"
fi

DEVELOPER_DIR="$converter" /usr/bin/xcodebuild -quiet -project "$project" -convert-project 'Xcode Project'
[[ -f "$project/project.xcproj" && ! -e "$project/project.pbxproj" ]] || {
    echo "error: Xcode did not replace project.pbxproj with project.xcproj." >&2
    exit 1
}
previous="$backup"
backup=""
if ! /usr/bin/trash "$previous"; then
    echo "warning: Conversion succeeded; recovery files retained at $previous because Trash was unavailable." >&2
fi
