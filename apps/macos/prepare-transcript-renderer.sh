#!/bin/sh
set -eu

directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$#" -eq 3 ] || { printf '%s\n' 'Usage: sh prepare-transcript-renderer.sh CHECKOUT CACHE DESTINATION' >&2; exit 1; }
dependencies="$1/apps/web/node_modules"
cache=$2
destination=$3
mkdir -p "$cache" "$destination"
staging=$(mktemp -d "$cache/.prepare.XXXXXX")
trap 'rm -rf "$staging"' EXIT
trap 'exit 1' HUP INT TERM

integrity() {
  openssl dgst -sha512 -binary "$1" | openssl base64 -A
}

install_asset() {
  name=$1
  version=$2
  checksum=$3
  resource=$4
  package="$dependencies/$name"
  installed_version=$(plutil -extract version raw -o - "$package/package.json" 2>/dev/null || true)
  if [ "$installed_version" = "$version" ] && [ -s "$package/dist/$resource" ] && [ -s "$package/LICENSE" ]; then
    install -m 644 "$package/dist/$resource" "$destination/$resource"
    install -m 644 "$package/LICENSE" "$destination/$name-LICENSE.txt"
    return
  fi

  archive="$cache/$name-$version.tgz"
  if [ ! -s "$archive" ] || [ "$(integrity "$archive")" != "$checksum" ]; then
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 90 --retry 2 --output "$staging/$name.tgz" \
      "https://registry.npmjs.org/$name/-/$name-$version.tgz"
    if [ "$(integrity "$staging/$name.tgz")" != "$checksum" ]; then
      printf 'Archive integrity did not match for %s %s.\n' "$name" "$version" >&2
      exit 1
    fi
    mv "$staging/$name.tgz" "$archive"
  fi
  tar -xOzf "$archive" "package/dist/$resource" > "$destination/$resource"
  tar -xOzf "$archive" package/LICENSE > "$destination/$name-LICENSE.txt"
}

install_asset katex 0.18.10 '/B6p9eY9DX7aHBfpkHdpirDTZ5QH9xTwL9y837PWuzuv41O5jFdqNQwVQEQsimY0/iVNkwBY4+4hMfhQ7d4Dbw==' katex.min.js
install_asset pele 1.8.0 'AYmHttE70cwNJVXdfPMCANGivFlmc3bGGpMG0GqH5S5vE3RgtEuLlkqbhRfe94Csv/ZEd1TUbv2dMUHpw4p1Bg==' pele.global.js
install_asset dompurify 3.4.17 'B/pSlYVHQ58kqISD/yDjuJ1yfzI34m1gF4lAod2bwSRhiN4K5Cl3H8Af7hqB2PmTL911tdEudnnXn5FnhRoz0w==' purify.min.js
install -m 644 "$directory/Assets/TranscriptRenderer/index.html" "$directory/Assets/TranscriptRenderer/render.js" "$destination/"

parser_node=${T3_APPKIT_RENDERER_NODE:-$(command -v node || true)}
parser="$directory/Assets/TranscriptRenderer/MathParser"
parser_source="$parser/math-parser.js.txt"
if [ -n "$parser_node" ] && [ -f "$1/packages/shared/src/markdownMath.ts" ] &&
   [ -d "$1/packages/shared/node_modules/remark-math" ] && [ -d "$1/node_modules/vite-plus" ]; then
  parser="$staging/MathParser"
  "$parser_node" "$directory/prepare-transcript-math.mjs" "$1" "$parser"
  parser_source="$parser/math-parser.js"
fi
install -m 644 "$parser_source" "$destination/math-parser.js"
install -m 644 "$parser/MathParser-LICENSES.md" "$destination/"

app_host="$directory/Assets/TranscriptRenderer/McpAppHost"
app_source="$app_host/mcp-app-host.js.txt"
if [ -n "$parser_node" ] && [ -f "$1/packages/client-runtime/src/mcpApps/host.ts" ] &&
   [ -d "$1/packages/client-runtime/node_modules/effect" ] && [ -d "$1/node_modules/vite-plus" ]; then
  app_host="$staging/McpAppHost"
  "$parser_node" "$directory/prepare-transcript-math.mjs" "$1" "$app_host" mcp-app
  app_source="$app_host/mcp-app-host.js"
fi
install -m 644 "$app_source" "$destination/mcp-app-host.js"
install -m 644 "$app_host/McpAppHost-LICENSES.md" "$directory/Assets/TranscriptRenderer/mcp-app-bridge.js" "$destination/"
