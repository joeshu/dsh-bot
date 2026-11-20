#!/usr/bin/env bash
# Build the full iPhoneOS and Simulator NodeMobile 24.22.3 XCFramework from pinned sources on macOS.
# Supports single-slice parallel CI builds (--slice=arm64 | --slice=arm64-simulator),
# fast assembly (--assemble device.zip simulator.zip out.zip), and single-command local builds (out.zip).
set -euo pipefail

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "This script requires Apple Silicon macOS with Xcode." >&2
  exit 2
}

MOBILE_COMMIT=b5bcc8d8e70f055333cd5efc317e3eb55bf0c9a5
PATCH_SHA=c04d714db5a861f4934ee6649be9a0ed689138485e1dc975e8ed26cb0ee55f84
PATCH_URL=https://github.com/nodejs/node/compare/ce7aaf1cee78b8cf0ce17364260535c418d3ed26...e63cab040c09d43ceef8cb35508c40044614e906.diff

abs_new_out() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  local out="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
  [[ ! -e "$out" ]] || { echo "Output already exists: $out" >&2; exit 2; }
  printf '%s' "$out"
}

strip_signature() {
  local framework="$1"
  if codesign -d "$framework" >/dev/null 2>&1; then
    codesign --remove-signature "$framework/NodeMobile"
  fi
  rm -rf "$framework/_CodeSignature"
}

prepare_source() {
  local workdir="$1"
  cd "$workdir"
  git init source
  git -C source fetch --depth=1 https://github.com/fogtape/nodejs-mobile.git "$MOBILE_COMMIT"
  git -C source checkout --detach FETCH_HEAD
  test "$(git -C source rev-parse HEAD)" = "$MOBILE_COMMIT"
  curl --fail --location --retry 3 --output node-security.diff "$PATCH_URL"
  echo "$PATCH_SHA  node-security.diff" | shasum -a 256 -c -
  git -C source apply --check ../node-security.diff
  git -C source apply ../node-security.diff
  grep -Eq '^#define NODE_PATCH_VERSION 3$' source/src/node_version.h
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "${1:-}" in
  --slice=arm64|--slice=arm64-simulator)
    [[ $# == 2 ]] || { echo "Usage: $0 --slice=arm64|arm64-simulator output.zip" >&2; exit 2; }
    SLICE="${1#--slice=}"
    OUT="$(abs_new_out "$2")"
    prepare_source "$TMP"
    cd "$TMP/source"
    export NODEJS_MOBILE_FLAVOR=full
    bash tools/ios_framework_prepare.sh "$SLICE"
    if [[ "$SLICE" == "arm64" ]]; then
      FW="out_ios_arm64/iphoneos-arm64/Release-iphoneos/NodeMobile.framework"
    else
      FW="out_ios_arm64-simulator/iphonesimulator-arm64/Release-iphonesimulator/NodeMobile.framework"
    fi
    strip_signature "$FW"
    mkdir -p "$TMP/slice"
    cp -R "$FW" "$TMP/slice/NodeMobile.framework"
    cp LICENSE "$TMP/slice/NodeMobile-LICENSE.txt"
    cd "$TMP/slice"
    zip -qry -9 "$OUT" NodeMobile.framework NodeMobile-LICENSE.txt
    shasum -a 256 "$OUT"
    ;;
  --assemble)
    [[ $# == 4 ]] || { echo "Usage: $0 --assemble device-slice.zip simulator-slice.zip output.zip" >&2; exit 2; }
    DEV_ZIP="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    SIM_ZIP="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
    OUT="$(abs_new_out "$4")"
    mkdir -p "$TMP/dev" "$TMP/sim" "$TMP/package"
    unzip -q "$DEV_ZIP" -d "$TMP/dev"
    unzip -q "$SIM_ZIP" -d "$TMP/sim"
    strip_signature "$TMP/dev/NodeMobile.framework"
    strip_signature "$TMP/sim/NodeMobile.framework"
    xcodebuild -create-xcframework \
      -framework "$TMP/dev/NodeMobile.framework" \
      -framework "$TMP/sim/NodeMobile.framework" \
      -output "$TMP/package/NodeMobile.xcframework"
    cp "$TMP/dev/NodeMobile-LICENSE.txt" "$TMP/package/NodeMobile-LICENSE.txt"
    cd "$TMP/package"
    zip -qry -9 "$OUT" NodeMobile.xcframework NodeMobile-LICENSE.txt
    shasum -a 256 "$OUT"
    ;;
  *)
    [[ $# == 1 ]] || { echo "Usage on Apple Silicon with Xcode: $0 output.zip" >&2; exit 2; }
    OUT="$(abs_new_out "$1")"
    prepare_source "$TMP"
    cd "$TMP/source"
    export NODEJS_MOBILE_FLAVOR=full
    bash tools/ios_framework_prepare.sh arm64
    bash tools/ios_framework_prepare.sh arm64-simulator
    DEVICE=out_ios_arm64/iphoneos-arm64/Release-iphoneos/NodeMobile.framework
    SIMULATOR=out_ios_arm64-simulator/iphonesimulator-arm64/Release-iphonesimulator/NodeMobile.framework
    strip_signature "$DEVICE"
    strip_signature "$SIMULATOR"
    mkdir "$TMP/package"
    xcodebuild -create-xcframework -framework "$DEVICE" -framework "$SIMULATOR" \
      -output "$TMP/package/NodeMobile.xcframework"
    cp LICENSE "$TMP/package/NodeMobile-LICENSE.txt"
    cd "$TMP/package"
    zip -qry -9 "$OUT" NodeMobile.xcframework NodeMobile-LICENSE.txt
    shasum -a 256 "$OUT"
    ;;
esac
