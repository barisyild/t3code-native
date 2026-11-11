#!/bin/sh
set -eu

directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
open_after_build=false
include_source_runtime=true
for argument in "$@"; do
  case "$argument" in
    --open) open_after_build=true ;;
    --client-only) include_source_runtime=false ;;
    --help) printf '%s\n' 'Usage: sh build.sh [--open] [--client-only]'; exit 0 ;;
    *) printf 'Unknown build option: %s\n' "$argument" >&2; exit 2 ;;
  esac
done
case ${T3_APPKIT_CONFIGURATION:-release} in
  debug|Debug) configuration=Debug ;;
  release|Release) configuration=Release ;;
  *) printf '%s\n' 'T3_APPKIT_CONFIGURATION must be debug or release.' >&2; exit 1 ;;
esac
build="$directory/.build"
bundle="$build/T3 Code AppKit.app"
derived="$build/xcode"
packages="$build/xcode-packages"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"

config_root="$directory"
case "$directory" in
  */apps/macos)
    checkout=${directory%/apps/macos}
    if [ -f "$checkout/apps/server/package.json" ]; then config_root="$checkout"; fi
    ;;
esac
node_runtime=""
if "$include_source_runtime" && [ -f "$config_root/apps/server/src/bin.ts" ]; then
  node_version=$(plutil -extract engines.node raw -o - "$config_root/package.json")
  node_runtime=$(sh "$directory/prepare-node.sh" "$node_version" "$build/runtime")
fi

(cd "$directory" && xcodebuild -quiet -resolvePackageDependencies -scheme T3CodeAppKit \
  -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$packages" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates) >&2

# SwiftTerm uses its Core Graphics renderer, so the build does not need the Metal toolchain.
(cd "$directory" && xcodebuild -quiet -scheme T3CodeAppKit -configuration "$configuration" \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$packages" \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO EXCLUDED_SOURCE_FILE_NAMES=Shaders.metal build) >&2
bin="$derived/Build/Products/$configuration"
staging=$(mktemp -d "$build/appkit-bundle.XXXXXX")
cleanup() {
  if [ -d "$staging/previous.app" ] && [ ! -d "$bundle" ]; then
    mv "$staging/previous.app" "$bundle"
  fi
  rm -rf "$staging"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
app="$staging/T3 Code AppKit.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin/T3Code" "$app/Contents/MacOS/T3Code"
install -m 644 "$directory/Info.plist" "$app/Contents/Info.plist"
install -m 644 "$packages/checkouts/SwiftTerm/LICENSE" "$app/Contents/Resources/SwiftTerm-LICENSE.txt"
install -m 644 "$packages/checkouts/clerk-ios/LICENSE" "$app/Contents/Resources/ClerkKit-LICENSE.txt"
install -m 644 "$directory/Assets/Providers/ClaudeProvider.png" "$directory/Assets/Providers/CodexProvider.png" "$app/Contents/Resources/"
cp -R "$bin/Clerk_ClerkKit.bundle" "$app/Contents/Resources/"
T3_APPKIT_RENDERER_NODE="$node_runtime" sh "$directory/prepare-transcript-renderer.sh" "$config_root" "$build/transcript-renderer-cache" \
  "$app/Contents/Resources/TranscriptRenderer"

if [ -n "$node_runtime" ]; then
  plutil -insert T3CODE_SOURCE_ROOT -string "$config_root" "$app/Contents/Info.plist"
  install -m 644 "$directory/server-compatibility.mjs" "$app/Contents/Resources/server-compatibility.mjs"
  mkdir -p "$app/Contents/Helpers"
  install -m 755 "$node_runtime" "$app/Contents/Helpers/node"
  install -m 644 "$(dirname "$node_runtime")/Node-LICENSE.txt" "$app/Contents/Resources/Node-LICENSE.txt"
  codesign --force --sign - "$app/Contents/Helpers/node" >&2
fi
if [ -f "$directory/.env" ] || [ -f "$directory/.env.local" ] ||
   [ -f "$config_root/.env" ] || [ -f "$config_root/.env.local" ] ||
   [ -n "${T3CODE_RELAY_URL:-}${VITE_T3CODE_RELAY_URL:-}" ]; then
  "${node_runtime:-node}" --input-type=module -e '
    import { execFileSync } from "node:child_process";
    import { existsSync, readFileSync } from "node:fs";
    import { join } from "node:path";
    import { parseEnv } from "node:util";

    const [module, checkout, plist] = process.argv.slice(1);
    const paths = [...new Set([module, checkout])].flatMap(directory =>
      [".env.local", ".env"].map(name => join(directory, name))
    );
    const sources = [process.env, ...paths.filter(existsSync).map(path => parseEnv(readFileSync(path, "utf8")))];
    const publicKeys = [
      ["T3CODE_RELAY_URL", "VITE_T3CODE_RELAY_URL"],
      ["T3CODE_CLERK_PUBLISHABLE_KEY", "VITE_CLERK_PUBLISHABLE_KEY", "EXPO_PUBLIC_CLERK_PUBLISHABLE_KEY"],
      ["T3CODE_CLERK_JWT_TEMPLATE", "VITE_CLERK_JWT_TEMPLATE", "EXPO_PUBLIC_CLERK_JWT_TEMPLATE"],
    ];
    for (const keys of publicKeys) {
      const value = sources.flatMap(source => keys.map(key => source[key]?.trim())).find(Boolean);
      if (value) execFileSync("plutil", ["-insert", keys[0], "-string", value, plist]);
    }
  ' "$directory" "$config_root" "$app/Contents/Info.plist"
fi

icon="$directory/Assets/AppIcon.png"
iconset="$staging/T3Code.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$app/Contents/Resources/T3Code.icns" "$iconset"
codesign --force --sign - "$app" >&2
codesign --verify --strict "$app"

if [ -d "$bundle" ]; then
  mv "$bundle" "$staging/previous.app"
fi
mv "$app" "$bundle"

printf '%s\n' "$bundle"
if "$open_after_build"; then
  open "$bundle"
fi
