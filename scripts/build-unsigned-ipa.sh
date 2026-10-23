#!/usr/bin/env bash
# Builds an unsigned FTPServer .ipa, for signing later (Sideloadly, AltStore, TrollStore,
# or re-signing with your own certificate and provisioning profile).
#
# Usage: scripts/build-unsigned-ipa.sh [options]
#   -c, --configuration NAME   Build configuration (default: Release)
#   -o, --output DIR           Where to put the .ipa, archive and log (default: build/)
#       --version X.Y.Z        App version to stamp in (default: MARKETING_VERSION in project.yml)
#       --build N              Build number to stamp in (default: CURRENT_PROJECT_VERSION)
#       --regenerate           Regenerate FTPServer.xcodeproj from project.yml with XcodeGen first
#   -h, --help                 Show this help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/FTPServer.xcodeproj"
SCHEME="FTPServer"
CONFIGURATION="Release"
OUTPUT_DIR="$ROOT/build"
REGENERATE=0
VERSION_OVERRIDES=()

usage() { sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration) CONFIGURATION="${2:?missing value for $1}"; shift 2 ;;
    -o|--output) OUTPUT_DIR="${2:?missing value for $1}"; shift 2 ;;
    --version) VERSION_OVERRIDES+=("MARKETING_VERSION=${2:?missing value for $1}"); shift 2 ;;
    --build) VERSION_OVERRIDES+=("CURRENT_PROJECT_VERSION=${2:?missing value for $1}"); shift 2 ;;
    --regenerate) REGENERATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v xcodebuild >/dev/null || { echo "✗ xcodebuild not found; install Xcode." >&2; exit 1; }

if [[ $REGENERATE -eq 1 || ! -d "$PROJECT" ]]; then
  command -v xcodegen >/dev/null || { echo "✗ xcodegen not found (brew install xcodegen)." >&2; exit 1; }
  echo "▸ Generating Xcode project…"
  (cd "$ROOT" && xcodegen generate --quiet)
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ARCHIVE="$OUTPUT_DIR/$SCHEME.xcarchive"
LOG="$OUTPUT_DIR/build.log"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "▸ Archiving $SCHEME ($CONFIGURATION, unsigned)…"
rm -rf "$ARCHIVE"
if ! xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$OUTPUT_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ${VERSION_OVERRIDES[@]+"${VERSION_OVERRIDES[@]}"} \
    >"$LOG" 2>&1; then
  grep -E "error:|FAILED" "$LOG" | sort -u | tail -20 >&2 || true
  echo "✗ Build failed. Full log: $LOG" >&2
  exit 1
fi

APP="$ARCHIVE/Products/Applications/$SCHEME.app"
[[ -d "$APP" ]] || { echo "✗ $APP not found in archive. Full log: $LOG" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
IPA="$OUTPUT_DIR/$SCHEME-$VERSION-$BUILD-unsigned.ipa"

echo "▸ Packaging…"
mkdir -p "$STAGING/Payload"
ditto "$APP" "$STAGING/Payload/$SCHEME.app"
# Make sure nothing signing-related slipped in, so the result is cleanly unsigned.
rm -rf "$STAGING/Payload/$SCHEME.app/_CodeSignature" "$STAGING/Payload/$SCHEME.app/embedded.mobileprovision"
rm -f "$IPA"
(cd "$STAGING" && zip -qry -X "$IPA" Payload)

echo "✓ $IPA"
echo "  Bundle ID:  $(plist CFBundleIdentifier)"
echo "  Version:    $VERSION ($BUILD), minimum iOS $(plist MinimumOSVersion)"
echo "  Arch:       $(lipo -archs "$APP/$(plist CFBundleExecutable)")"
echo "  Size:       $(du -h "$IPA" | cut -f1 | tr -d ' ')"
echo "  dSYMs:      $ARCHIVE/dSYMs"
