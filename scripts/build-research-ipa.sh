#!/bin/zsh
# Build the RESEARCH IPA (feedback #31) — pull diagnosis only.
#
# This build is the distribution build (restore route CLOSED — the
# research flag does not open DriftRestoreGate) plus the [MB2-PULL]
# session trace and one extra Settings entry, "诊断拉取". A gate-open
# variant for the spare-device end-to-end stage is a separate build
# decided separately; it is not a mode of this script.
#
#   ./scripts/build-research-ipa.sh [--skip-build]
#
# Output: build/research/Drift-research-unsigned.ipa
#
# How the research channel stays isolated from the distribution build:
#
#   * The build itself is the ordinary one (`scripts/build-ipa.sh`), from
#     the ordinary sources and the ordinary Info.plist. The distribution
#     plist in `layout/Applications/Drift.app/Info.plist` is NEVER edited.
#   * Only afterwards, on a COPY of the finished .app, this script injects
#     `DriftResearchBuild = true` into Info.plist (that key is what
#     `DriftResearchBuild.isActive` reads; see Drift/Core/
#     DriftResearchBuild.swift) and renames the home-screen label to
#     "Drift 研究版". The copy is rezipped under a different file name.
#   * A distribution IPA therefore cannot turn research by accident: the
#     key is absent, the gate reads closed, and the banner/actions do not
#     exist. Editing the key into an already-signed copy breaks its
#     signature, and only Grace signs.
#
# Publication (Grace's ruling, feedback #31): the research IPA goes to
# the soci-art/Drift Releases as a SEPARATE PRE-RELEASE whose title and
# notes lead with "DO NOT USE" and state, in Chinese: 研究专用、仅含诊
# 断拉取、恢复式仍处于停用状态、没有任何写回功能、不是功能版、测试
# 者勿装。 It must NEVER replace the v1.0.0 distribution asset.
#
# Repacking uses Info-ZIP (`zip -r -X`), not ditto/Python: Grace's
# signer (LCSign) refuses Python-zipfile containers.
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    *) echo "unknown argument: $arg (expected --skip-build)" >&2; exit 2 ;;
  esac
done

if (( ! SKIP_BUILD )); then
  ./scripts/build-ipa.sh Release
fi

SRC_IPA="build/Drift.ipa"
if [[ ! -f "$SRC_IPA" ]]; then
  echo "error: $SRC_IPA not found — run without --skip-build first" >&2
  exit 1
fi

OUT_DIR="build/research"
OUT_IPA="$OUT_DIR/Drift-research-unsigned.ipa"
mkdir -p "$OUT_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ditto -x -k "$SRC_IPA" "$WORK"
APP_PLIST="$WORK/Payload/Drift.app/Info.plist"
if [[ ! -f "$APP_PLIST" ]]; then
  echo "error: Payload/Drift.app/Info.plist not found inside $SRC_IPA" >&2
  exit 1
fi

# Inject the research key (Add the first time, Set if a re-run meets one).
/usr/libexec/PlistBuddy -c "Set :DriftResearchBuild true" "$APP_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :DriftResearchBuild bool true" "$APP_PLIST"
# Make the installed app distinguishable on the home screen too.
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Drift 研究版" "$APP_PLIST"

# Verify the injection landed before packaging: a research IPA without
# the key is just a second distribution IPA with a confusing name.
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :DriftResearchBuild' "$APP_PLIST")" != "true" ]]; then
  echo "error: DriftResearchBuild key did not land in the research copy" >&2
  exit 1
fi

rm -f "$OUT_IPA"
( cd "$WORK" && zip -r -X -q "$OLDPWD/$OUT_IPA" Payload )

echo "research IPA: $OUT_IPA"
shasum -a 256 "$OUT_IPA"
echo "REMINDER: publish ONLY as a separate DO-NOT-USE pre-release (feedback #31);"
echo "never replace the v1.0.0 distribution asset."
