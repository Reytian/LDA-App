#!/bin/bash
# Regenerate Frameworks/llama.xcframework from a llama.cpp checkout.
# Produces a static-library xcframework (Metal shaders embedded) holding the
# core llama.cpp C API, which LDACore links via the Cllama binary target.
#
# Usage: ./scripts/build-llama-xcframework.sh [path-to-llama.cpp]
# Defaults to ~/Developer/llama.cpp. Requires cmake and Xcode command line tools.
#
# House rules: English only. No em-dash or en-dash-as-separator.
set -euo pipefail

SRC="${1:-$HOME/Developer/llama.cpp}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCF="$REPO_ROOT/Frameworks/llama.xcframework"
STAGE="$(mktemp -d)"

echo "llama.cpp source: $SRC"

if [ ! -d "$SRC/build" ] || [ ! -f "$SRC/build/src/libllama.a" ]; then
  echo "Configuring and building static libraries (Metal embedded)..."
  cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF >/dev/null
  cmake --build "$SRC/build" --config Release -j8 \
    --target llama ggml ggml-base ggml-cpu ggml-metal ggml-blas
fi

echo "Merging static archives (core C API only)..."
libtool -static -o "$STAGE/libllama_combined.a" \
  "$SRC/build/src/libllama.a" \
  "$SRC/build/ggml/src/libggml.a" \
  "$SRC/build/ggml/src/libggml-base.a" \
  "$SRC/build/ggml/src/libggml-cpu.a" \
  "$SRC/build/ggml/src/ggml-metal/libggml-metal.a" \
  "$SRC/build/ggml/src/ggml-blas/libggml-blas.a"

echo "Assembling xcframework by hand (xcodebuild -create-xcframework is flaky here)..."
rm -rf "$XCF"
mkdir -p "$XCF/macos-arm64/Headers"
cp "$STAGE/libllama_combined.a" "$XCF/macos-arm64/libllama_combined.a"
cp "$SRC/include/"*.h "$XCF/macos-arm64/Headers/" 2>/dev/null || true
cp "$SRC/ggml/include/"*.h "$XCF/macos-arm64/Headers/"
printf '#include "llama.h"\n' > "$XCF/macos-arm64/Headers/cllama.h"
cat > "$XCF/macos-arm64/Headers/module.modulemap" <<'MM'
module Cllama {
    header "cllama.h"
    export *
}
MM
cat > "$XCF/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>LibraryIdentifier</key><string>macos-arm64</string>
      <key>LibraryPath</key><string>libllama_combined.a</string>
      <key>HeadersPath</key><string>Headers</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>macos</string>
    </dict>
  </array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST

rm -rf "$STAGE"
echo "Done: $XCF"
