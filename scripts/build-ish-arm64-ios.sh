#!/usr/bin/env bash
# Build the source-pinned OpenMinis iSH ARM64 engine for iPhoneOS and Simulator.
# This produces engine libraries only; app integration is intentionally gated
# until the native task, PTY, fakefs routing, and recovery contracts are wired.
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
command -v python3 >/dev/null
command -v meson >/dev/null
command -v ninja >/dev/null
command -v xcrun >/dev/null
xcode-select -p >/dev/null

mkdir -p "$BUILD_ROOT" "$OUT"
python3 - "$LOCK" "$BUILD_ROOT" <<'PY'
import json
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
script = checkout / lock["distribution"]["buildScript"]
import hashlib
digest = hashlib.sha256(script.read_bytes()).hexdigest()
if digest != lock["distribution"]["buildScriptSha256"]:
    raise SystemExit(f"OpenMinis build script changed: sha256={digest}")
print(f"Pinned OpenMinis {commit} and iSH ARM64 {lock['engine']['commit']}")
PY

OPENMINIS="$BUILD_ROOT/OpenMinis"
"$OPENMINIS/deps/build_ish.sh" release --all
python3 "$ROOT/scripts/package-ish-arm64-ios.py" \
  --lock "$LOCK" \
  --distribution-root "$OPENMINIS" \
  --output "$OUT"
echo "Built source-pinned iSH ARM64 library artifact: $OUT"
