#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
target="$root/macos/Resources/extension-viewer"
files=(viewer.html viewer.js viewer.css)
release_base="https://github.com/ipetinate/phantom-extensions/releases/download/viewer"

usage() {
    cat >&2 <<EOF
usage:
  $0 --from <dir> [<version>]
      Copy viewer.html, viewer.js and viewer.css from a local phantom-mdx build
      (packages/phantom-mdx/dist/viewer in the registry checkout). The version
      is read from the package.json two levels above <dir> unless given.

  $0 <version> <sha256>
      Download phantom-mdx-viewer-<version>.zip from the registry's "viewer"
      release, check its digest, and unpack the three files.

Both forms rewrite VERSION and print the digests of the three files for the
README beside them. macos/Resources/extension-viewer has to be clean in git.
EOF
    exit 2
}

fail() {
    echo "error: $*" >&2
    exit 1
}

require_clean_target() {
    if [ -n "$(git -C "$root" status --porcelain -- macos/Resources/extension-viewer)" ]; then
        fail "macos/Resources/extension-viewer has uncommitted changes; commit or discard them first"
    fi
}

check_semver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "'$1' is not a version of the form X.Y.Z"
}

version_from_package() {
    local package="$1"
    [ -f "$package" ] || fail "no package.json at $package; pass the version explicitly"
    sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$package" | head -n 1
}

install_files() {
    local source="$1" version="$2"
    for file in "${files[@]}"; do
        [ -f "$source/$file" ] || fail "$source/$file is missing"
    done
    mkdir -p "$target"
    for file in "${files[@]}"; do
        cp "$source/$file" "$target/$file"
    done
    printf '%s\n' "$version" > "$target/VERSION"

    echo "extension-viewer is now phantom-mdx $version"
    (cd "$target" && shasum -a 256 "${files[@]}")
}

[ $# -ge 1 ] || usage

if [ "$1" = "--from" ]; then
    [ $# -ge 2 ] || usage
    source_dir="$(cd "$2" && pwd)"
    if [ $# -ge 3 ]; then
        version="$3"
    else
        version="$(version_from_package "$source_dir/../../package.json")"
    fi
    check_semver "$version"
    require_clean_target
    install_files "$source_dir" "$version"
    exit 0
fi

[ $# -eq 2 ] || usage
version="$1"
digest="$2"
check_semver "$version"
[[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || fail "'$digest' is not a sha256 digest"
require_clean_target

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

archive="$scratch/phantom-mdx-viewer-$version.zip"
curl --fail --location --silent --show-error \
    --output "$archive" \
    "$release_base/phantom-mdx-viewer-$version.zip"
(cd "$scratch" && echo "$digest  phantom-mdx-viewer-$version.zip" | shasum -a 256 -c -)

unzip -q "$archive" -d "$scratch/unpacked"
if [ -d "$scratch/unpacked/viewer" ]; then
    unpacked="$scratch/unpacked/viewer"
else
    unpacked="$scratch/unpacked"
fi
install_files "$unpacked" "$version"
