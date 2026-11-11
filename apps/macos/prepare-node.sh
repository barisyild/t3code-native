#!/bin/sh
set -eu

fail() { printf '%s\n' "$1" >&2; exit 1; }
[ "$#" -eq 2 ] || fail 'Usage: sh prepare-node.sh NODE_VERSION CACHE_DIRECTORY'
version=$1
if ! printf '%s\n' "$version" | awk 'NR == 1 && /^[0-9]+\.[0-9]+\.[0-9]+$/ { valid = 1 } END { exit !(valid && NR == 1) }'; then
  fail 'The checkout must specify an exact Node.js version in package.json engines.node.'
fi
case $(uname -m) in
  arm64) architecture=arm64 ;;
  x86_64) architecture=x64 ;;
  *) fail 'No Node.js runtime is available for this Mac architecture.' ;;
esac

release="node-v$version-darwin-$architecture"
runtime="$2/$release"
if [ -x "$runtime/node" ] && [ -s "$runtime/Node-LICENSE.txt" ] &&
   [ "$("$runtime/node" --version 2>/dev/null || true)" = "v$version" ]; then
  printf '%s\n' "$runtime/node"
  exit 0
fi

mkdir -p "$runtime"
staging=$(mktemp -d "$runtime/.prepare.XXXXXX")
trap 'rm -rf "$staging"' EXIT
trap 'exit 1' HUP INT TERM
archive="$release.tar.gz"
origin="https://nodejs.org/dist/v$version"
fetch() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 120 --retry 2 --output "$2" "$1"
}

printf 'Preparing Node.js %s for macOS %s\n' "$version" "$architecture" >&2
fetch "$origin/SHASUMS256.txt" "$staging/checksums"
checksum=$(awk -v archive="$archive" '$2 == archive && length($1) == 64 && $1 ~ /^[a-fA-F0-9]+$/ { print $1 }' "$staging/checksums")
[ "${#checksum}" -eq 64 ] || fail "The official Node.js checksums do not contain $archive."
fetch "$origin/$archive" "$staging/$archive"
(cd "$staging" && printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -) >&2
tar -xzf "$staging/$archive" -C "$staging" "$release/bin/node" "$release/LICENSE"
[ "$("$staging/$release/bin/node" --version)" = "v$version" ] || fail 'The downloaded Node.js runtime reports a different version.'
[ -s "$staging/$release/LICENSE" ] || fail 'The downloaded Node.js runtime is missing its license.'
install -m 644 "$staging/$release/LICENSE" "$runtime/Node-LICENSE.txt"
mv "$staging/$release/bin/node" "$runtime/node"
printf '%s\n' "$runtime/node"
