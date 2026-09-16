#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
series="$script_dir/patches/series"
[ -s "$series" ] || { printf 'ERROR: missing patch series\n' >&2; exit 1; }
checksums=
while IFS= read -r patch_file || [ -n "$patch_file" ]; do
    case "$patch_file" in
        ''|*[!a-zA-Z0-9._-]*) printf 'ERROR: invalid patch filename\n' >&2; exit 1 ;;
    esac
    patch_path="$script_dir/patches/$patch_file"
    if [ ! -s "$patch_path" ] || [ ! -r "$patch_path" ]; then
        printf 'ERROR: missing or empty patch: %s\n' "$patch_file" >&2; exit 1;
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        patch_hash=$(sha256sum "$patch_path")
    else
        patch_hash=$(shasum -a 256 "$patch_path")
    fi
    checksums="${checksums}${patch_hash%% *}  $patch_file
"
done <"$series"
[ -n "$checksums" ]
if command -v sha256sum >/dev/null 2>&1; then
    series_hash=$(printf '%s' "$checksums" | sha256sum)
else
    series_hash=$(printf '%s' "$checksums" | shasum -a 256)
fi
printf '%s\n' "${series_hash%% *}"
