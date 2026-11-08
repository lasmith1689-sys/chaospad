#!/bin/bash
# Builds ChaosPad: Splinter Cell Chaos Theory (USA) as native iPhone/iPad code, on the ps2-native-recomp runtime (vendored in
# runtime/, MIT, with my iOS port: host/ios/, host/touchpad.cpp) plus my decrypted game input. The input holds the game's
# program (core.elf = SC3_OFF.ELF), the guest arguments its launcher passes (args.txt) and the C++ generated from them on my PC
# (generated/: the recompiled EE code and the VU1 microprograms compiled ahead of time). Nothing is recompiled here; this only
# compiles. Nothing is compiled on the phone either: the app is built with PS2_NO_LIVE.
#
# Usage: build-ios.sh INPUT_DIR WORK_DIR [device|simulator]
#   INPUT_DIR  core.elf, args.txt, generated/
#   WORK_DIR   scratch space; the app ends up at WORK_DIR/ChaosPad.app
# Environment: CHAOSPAD_BUNDLE_ID, CMAKE_BUILD_PARALLEL_LEVEL
set -euo pipefail

input=$(cd "$1" && pwd)
mkdir -p "$2"
work=$(cd "$2" && pwd)
target=${3:-device}
root=$(cd "$(dirname "$0")/../.." && pwd)
jobs=${CMAKE_BUILD_PARALLEL_LEVEL:-$(sysctl -n hw.ncpu)}
case "$target" in
  device) sysroot=iphoneos; platform=iPhoneOS; triple=arm64-apple-ios26.0
          wgpu_zip=wgpu-ios-aarch64-release.zip; wgpu_sha=e36c9913b9e5095a530fa9121c50b16a4e3dd020e1eebf601f2f47ce24d56941 ;;
  simulator) sysroot=iphonesimulator; platform=iPhoneSimulator; triple=arm64-apple-ios26.0-simulator
          wgpu_zip=wgpu-ios-aarch64-simulator-release.zip; wgpu_sha=750e706765bef3744313745194774d095c916fc21d2a0e7d4d7b0bc4d0c92789 ;;
  *) echo "::error::target must be device or simulator"; exit 1 ;;
esac
bundle=${CHAOSPAD_BUNDLE_ID:-com.lasmith1689.chaospad}
group="group.$bundle"  # shared by the app and its Background Assets downloader extension

echo "▶ Third-party sources (checked against their SHA-256)"
fetch() {  # url sha256 file
  curl -fsSL -o "$work/$3" "$1"
  echo "$2  $work/$3" | shasum -a 256 -c - > /dev/null || { echo "::error::$3: wrong SHA-256"; exit 1; }
}
fetch "https://github.com/gfx-rs/wgpu-native/releases/download/v29.0.1.1/$wgpu_zip" "$wgpu_sha" wgpu.zip
rm -rf "$work/wgpu" && mkdir -p "$work/wgpu" && unzip -q -o "$work/wgpu.zip" -d "$work/wgpu"
ls "$work/wgpu" "$work/wgpu/lib"
fetch "https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz" \
  5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165 sdl2.tar.gz
rm -rf "$work/SDL2-2.32.10" && tar -xzf "$work/sdl2.tar.gz" -C "$work"

echo "▶ The app's game folder"
rm -rf "$work/game" && mkdir -p "$work/game"
cp "$input/core.elf" "$input/args.txt" "$work/game/"
echo "  $(find "$input/generated" -name '*.cpp' | wc -l | tr -d ' ') generated C++ files, $(du -sh "$input/generated" | cut -f1)"

echo "▶ iOS build ($target, $jobs jobs)"
# -ffp-contract=off: no fused multiply-add (arm64 has it, and clang would fuse): the vector units must round like the PS2's
cmake -S "$root/runtime" -B "$work/build" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$sysroot -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_BUILD_TYPE=Release "-DCMAKE_CXX_FLAGS=-ffp-contract=off" \
  -DPS2_GENERATED="$input/generated" -DPS2_WGPU_DIR="$work/wgpu" -DPS2_SDL2_SOURCE="$work/SDL2-2.32.10" \
  -DPS2_IOS_GAME_DIR="$work/game" -DPS2_IOS_APP_NAME=ChaosPad "-DPS2_IOS_DISPLAY_NAME=Chaos Theory" \
  -DPS2_IOS_BUNDLE_ID="$bundle" -DPS2_IOS_APP_GROUP="$group" -DPS2_IOS_PLATFORM=$platform \
  -DPS2_IOS_ASSET_PACK=sc3disc -DPS2_IOS_DISC_FILE=sc3.sparse \
  > "$work/ios-configure.log" 2>&1 || { tail -80 "$work/ios-configure.log"; exit 1; }
start=$SECONDS
cmake --build "$work/build" --target ps2run -j "$jobs" -- -k 0 > "$work/ios-build.log" 2>&1 || {
  grep -E "error:|FAILED" "$work/ios-build.log" | sort -u | head -150; tail -40 "$work/ios-build.log"; exit 1; }
echo "  compiled in $(( (SECONDS - start) / 60 )) min"
grep -E "warning:" "$work/ios-build.log" | grep -v "generated/" | sort -u | head -40 || true

app=$(find "$work/build" -maxdepth 2 -name 'ChaosPad.app' -type d | head -n 1)
[ -n "$app" ] || { echo "::error::ChaosPad.app was not produced"; exit 1; }
rm -rf "$work/ChaosPad.app"
ditto "$app" "$work/ChaosPad.app"
app="$work/ChaosPad.app"
plutil -lint "$app/Info.plist"

echo "▶ Background Assets downloader extension (Apple-hosted asset packs, iOS 26)"
ext="$app/Extensions/ChaosPadDownloader.appex"
mkdir -p "$ext"
# (linked like Xcode's extensionkit-extension product type, whose LD_ENTRY_POINT is _NSExtensionMain)
xcrun --sdk $sysroot swiftc -target $triple -parse-as-library -application-extension -O -module-name ChaosPadDownloader \
  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -application_extension \
  "$root/ios/downloader/DownloaderExtension.swift" -o "$ext/ChaosPadDownloader"
sed -e "s|@BUNDLE_ID@|$bundle.downloader|" -e "s|@PLATFORM@|$platform|" "$root/ios/downloader/Info.plist" > "$ext/Info.plist"
plutil -lint "$ext/Info.plist"
# entitlements for signing (testflight.sh, simulator-check.sh): the app group of both bundles
sed "s|@APP_GROUP@|$group|" "$root/ios/ChaosPad.entitlements" > "$work/ChaosPad.entitlements"
sed "s|@APP_GROUP@|$group|" "$root/ios/downloader/ChaosPadDownloader.entitlements" > "$work/ChaosPadDownloader.entitlements"

echo "▶ App icon"
icons="$work/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$icons"
cp "$root/game/AppIcon-1024.png" "$icons/AppIcon-1024.png"
cat > "$icons/Contents.json" <<'EOF'
{ "images": [ { "filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ],
  "info": { "author": "xcode", "version": 1 } }
EOF
printf '{ "info": { "author": "xcode", "version": 1 } }\n' > "$work/Assets.xcassets/Contents.json"
xcrun actool "$work/Assets.xcassets" --compile "$app" --platform $sysroot --minimum-deployment-target 26.0 \
  --app-icon AppIcon --target-device iphone --target-device ipad \
  --output-partial-info-plist "$work/icon-info.plist" > "$work/actool.log"
/usr/libexec/PlistBuddy -c "Merge $work/icon-info.plist" "$app/Info.plist"

ls -la "$app" | head -n 30
du -sh "$app"
