#!/usr/bin/env bash
# Build source-pinned OpenMinis iSH ARM64 libraries and a pinned Alpine fakefs
# rootfs for iPhoneOS and Simulator. The app runtime remains separately gated
# until lifecycle, PTY, project routing, and recovery are wired.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/scripts/ish-arm64-sources.lock.json"
OUT="${DSBOT_ISH_OUT_DIR:-$ROOT/dist/ish-arm64-ios}"
BUILD_ROOT="${DSBOT_ISH_BUILD_ROOT:-$(mktemp -d)}"
OWN_BUILD_ROOT=0
if [[ -z "${DSBOT_ISH_BUILD_ROOT:-}" ]]; then OWN_BUILD_ROOT=1; fi
cleanup() { if [[ "$OWN_BUILD_ROOT" == 1 ]]; then rm -rf "$BUILD_ROOT"; fi; }
trap cleanup EXIT

if [[ "$(uname -s)" != Darwin ]]; then
  echo "iSH iOS libraries must be cross-compiled with the macOS Xcode SDKs." >&2
  exit 2
fi
command -v git >/dev/null
command -v patch >/dev/null
command -v python3 >/dev/null
command -v meson >/dev/null
command -v ninja >/dev/null
command -v xcrun >/dev/null
xcode-select -p >/dev/null

mkdir -p "$BUILD_ROOT" "$OUT"
python3 - "$LOCK" "$BUILD_ROOT" <<'PY'
import json
import hashlib
import subprocess
import sys
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
repo = lock["distribution"]["repository"]
commit = lock["distribution"]["commit"]
checkout = root / "OpenMinis"
subprocess.run(["git", "clone", "--filter=blob:none", "--no-checkout", repo, str(checkout)], check=True)
subprocess.run(["git", "-C", str(checkout), "checkout", "--detach", commit], check=True)
actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
if actual != commit:
    raise SystemExit(f"OpenMinis source pin mismatch: {actual}")
gitlink = subprocess.check_output(["git", "-C", str(checkout), "ls-tree", "HEAD", "deps/ish"], text=True).split()
if len(gitlink) < 3 or gitlink[2] != lock["engine"]["commit"]:
    raise SystemExit("OpenMinis commit no longer points to the locked iSH engine commit")
subprocess.run(["git", "-C", str(checkout), "submodule", "update", "--init", "deps/ish"], check=True)
engine = checkout / "deps/ish"
actual = subprocess.check_output(["git", "-C", str(engine), "rev-parse", "HEAD"], text=True).strip()
if actual != lock["engine"]["commit"]:
    raise SystemExit(f"iSH source pin mismatch: {actual}")
for path, expected in lock["engine"]["submodules"].items():
    # The upstream iSH fork marks deps/linux update=none because it is only
    # needed for selected build variants. This iOS build requires all locked
    # submodules, so override that local hint before initializing the pin.
    subprocess.run(["git", "-C", str(engine), "config", f"submodule.{path}.update", "checkout"], check=True)
    subprocess.run(["git", "-C", str(engine), "submodule", "update", "--init", "--recursive", "--", path], check=True)
    actual = subprocess.check_output(["git", "-C", str(engine / path), "rev-parse", "HEAD"], text=True).strip()
    if actual != expected:
        raise SystemExit(f"iSH dependency pin mismatch for {path}: {actual}")
integration_patches = lock.get("hostIntegrationPatches", [])
if not integration_patches:
    raise SystemExit("The pinned iSH host integration patches are missing")
for record in integration_patches:
    patch_path = Path(sys.argv[1]).resolve().parent / record["path"]
    patch_bytes = patch_path.read_bytes()
    actual = hashlib.sha256(patch_bytes).hexdigest()
    if actual != record["sha256"]:
        raise SystemExit(f"iSH integration patch hash mismatch: {record['path']}")
    subprocess.run(
        ["patch", "--fuzz=0", "--batch", "--forward", "-p1", "-d", str(engine)],
        input=patch_bytes,
        check=True,
    )
    print(f"Applied pinned iSH host integration patch {record['path']} ({actual})")
script = checkout / lock["distribution"]["buildScript"]
digest = hashlib.sha256(script.read_bytes()).hexdigest()
if digest != lock["distribution"]["buildScriptSha256"]:
    raise SystemExit(f"OpenMinis build script changed: sha256={digest}")
print(f"Pinned OpenMinis {commit} and iSH ARM64 {lock['engine']['commit']}")
PY

OPENMINIS="$BUILD_ROOT/OpenMinis"
"$OPENMINIS/deps/build_ish.sh" release --all

# fakefsify is a host tool. Build it natively from the same pinned iSH source;
# do not use a separately downloaded or developer-local converter.
FAKEFSIFY_BUILD="$BUILD_ROOT/ish-fakefsify-native"
rm -rf "$FAKEFSIFY_BUILD"
meson setup "$FAKEFSIFY_BUILD" "$OPENMINIS/deps/ish" \
  --buildtype=release -Dlog="" -Dkernel=ish -Dengine=asbestos -Dguest_arch=arm64
ninja -C "$FAKEFSIFY_BUILD" tools/fakefsify

# Reuse the verified Alpine pin shared with the Linux guest-image builder.
MINIROOTFS_SOURCE="$BUILD_ROOT/alpine-minirootfs-source"
python3 "$ROOT/scripts/prepare-arm64-guest.py" \
  --minirootfs-only \
  --output "$MINIROOTFS_SOURCE" \
  --cache "$BUILD_ROOT/alpine-cache"
MINIROOTFS_FILENAME="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["file"]["path"])' \
  "$MINIROOTFS_SOURCE/source-manifest.json")"

python3 "$ROOT/scripts/package-ish-arm64-ios.py" \
  --lock "$LOCK" \
  --distribution-root "$OPENMINIS" \
  --guest-minirootfs "$MINIROOTFS_SOURCE/$MINIROOTFS_FILENAME" \
  --fakefsify "$FAKEFSIFY_BUILD/tools/fakefsify" \
  --output "$OUT"
echo "Built source-pinned iSH ARM64 libraries and Alpine fakefs rootfs: $OUT"
