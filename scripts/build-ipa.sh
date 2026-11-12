#!/bin/zsh
# Build an unsigned device IPA from the Xcode project.
# Usage: ./scripts/build-ipa.sh [Debug|Release] [--clean]   (default: Release)
# Output: build/Drift.ipa (unsigned — sideload via AltStore/SideStore/LiveContainer)
#
# --clean wipes build/xderived first.  Reach for it after touching anything
# under Vendor/: an incremental build can refresh a .swiftmodule WITHOUT
# relinking the app, so the build reports success while the IPA still carries
# the previous logic.  The staleness check below catches that either way, which
# is why it looks only at the linked binary and not at the modules.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Release"
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    Debug|Release) CONFIG="$arg" ;;
    --clean)       CLEAN=1 ;;
    *) echo "unknown argument: $arg (expected Debug, Release or --clean)" >&2; exit 2 ;;
  esac
done

# A failed build must never leave yesterday's IPA at the advertised path.
# Preserve the previous success under an explicitly historical name instead.
mkdir -p build
if [[ -f build/Drift.ipa ]]; then
  mkdir -p build/previous
  previous="build/previous/Drift-$(date +%Y%m%d-%H%M%S)-$$.ipa"
  mv build/Drift.ipa "$previous"
  echo "previous IPA preserved: $previous"
fi

DERIVED="$(pwd)/build/xderived"
if (( CLEAN )); then
  echo "cleaning $DERIVED"
  rm -rf "$DERIVED"
fi

xcodebuild -project Drift.xcodeproj \
  -scheme Drift \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build

APP_PATH="$DERIVED/Build/Products/${CONFIG}-iphoneos/Drift.app"
BINARY="$APP_PATH/Drift"
if [ ! -f "$BINARY" ]; then
  echo "error: expected app binary not found at $BINARY" >&2
  exit 1
fi

python3 scripts/check-car-appearances.py "$APP_PATH/Assets.car" --require-dark --name AppIcon

# Post-build staleness check.  A .swift newer than the linked binary means the
# app was NOT relinked — the exact shape of "build says OK, IPA has old code".
# The scan set is clean: no .swift lives under .build, .swiftpm or patches.
stale="$(find Nugget Vendor -name '*.swift' -newer "$BINARY" -print -quit 2>/dev/null || true)"
if [ -n "$stale" ]; then
  echo "error: $stale is newer than $BINARY" >&2
  echo "       the app binary was not relinked; re-run with --clean" >&2
  exit 1
fi

mkdir -p build
rm -rf build/Payload build/Drift.ipa
mkdir -p build/Payload
cp -R "$APP_PATH" build/Payload/Drift.app

# Keep the loose icon PNGs actool leaves at the bundle root.
#
# The icon is an Icon Composer stack inside Assets.xcassets, and actool compiles
# it into Assets.car — but it *also* writes the primary icon out as loose PNGs
# (AppIcon60x60@2x.png, AppIcon76x76@2x~ipad.png).
#
# Collection #204 (Grace, 2026-11-12) reverses the earlier drop: SideStore /
# AltStore only ever look for loose AppIcon*.png at the .app root and never
# read Assets.car, so without them Drift shows a blank icon there.  The cost
# is known and accepted: the loose files carry the LIGHT artwork only, and a
# loose icon at the bundle root wins over the catalog's rendition, so the
# Home Screen shows the light icon even in dark mode.  (Up to 3.0.9 (24) the
# rm below deleted them for exactly that reason; do not re-add it without
# re-opening #204.)

# Strip symbol tables out of the *copy* we are about to package, not out of
# DerivedData — the unstripped product stays available for debugging.  This
# build is unsigned (CODE_SIGNING_ALLOWED=NO above, the sideloader signs
# afterwards), so nothing is invalidated, and Release already asks Xcode for it
# via COPY_PHASE_STRIP; the explicit `strip` here makes the IPA lean regardless
# of which configuration produced it.  Worth ~8.5 MB raw: 47% of the app binary
# and 33% of EMProxy is symbol table, nearly all Rust names from statically
# linked vendored libraries.
for macho in build/Payload/Drift.app/Drift \
            build/Payload/Drift.app/Frameworks/EMProxy.framework/EMProxy; do
  if [ -f "$macho" ]; then
    before="$(stat -f%z "$macho")"
    strip -S "$macho"
    echo "stripped $macho: $before -> $(stat -f%z "$macho") bytes"
  fi
done

(cd build && zip -qry Drift.ipa Payload)
python3 scripts/repack-ipa.py build/Drift.ipa
rm -rf build/Payload

echo "done: build/Drift.ipa (unsigned, ${CONFIG})"
