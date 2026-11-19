#!/usr/bin/env bash
set -euo pipefail

lib_dir=${1:?expected directory containing libkrun.dylib}
identity=${2:--}
dylib="$lib_dir/libkrun.dylib"

# otool prints a header and the dylib's own install name before its dependencies.
dependencies=$(otool -L "$dylib" | sed -E '1,2d; s/^[[:space:]]+//; s/ \(compatibility version .*$//')
changes=()
while IFS= read -r dep; do
    case "$dep" in
        /System/Library/*|/usr/lib/*|'') continue ;;
    esac
    leaf=${dep##*/}
    if [[ ! -f "$lib_dir/$leaf" ]]; then
        echo "Error: $dylib depends on $dep but $leaf is missing from $lib_dir" >&2
        exit 1
    fi
    if [[ "$dep" != "@loader_path/$leaf" ]]; then
        changes+=(-change "$dep" "@loader_path/$leaf")
    fi
done <<< "$dependencies"

if (( ${#changes[@]} )); then
    install_name_tool "${changes[@]}" "$dylib"
fi
if [[ "$identity" != "-" ]]; then
    codesign --force --sign "$identity" --options runtime "$dylib"
elif (( ${#changes[@]} )); then
    codesign --force --sign - "$dylib"
fi
