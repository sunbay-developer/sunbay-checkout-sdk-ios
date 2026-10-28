#!/usr/bin/env bash
set -euo pipefail

# build-xcframework.sh
#
# On-demand packaging tool: builds an XCFramework from the SunbayCheckout SDK.
#
# Scope:
#   - Packages ONLY the `SunbayCheckout` library product.
#   - Does NOT package SunbayCheckoutTestSupport, the Example app (SunbayCheckoutDemo),
#     or the ApplePayProbe executable.
#   - Minimum deployment target: iOS 15 (matches Package.swift).
#
# Security:
#   - Produces NO signed artifacts and NO secret material: the result is an unsigned,
#     distributable static library/framework packaged as an .xcframework. No merchant
#     keys, certificates, tokens, or card data are involved.
#
# Repository hygiene:
#   - All output lives under build/ which is git-ignored. Nothing here is committed.
#   - This is an ON-DEMAND tool. Nothing in the normal build/test flow (swift build,
#     swift test) depends on it. Source SPM remains the primary distribution mechanism;
#     see docs/releasing.md for when/why to run this and the future binary-distribution
#     (C3) path.
#
# Failure behavior:
#   - `set -euo pipefail` means any failing xcodebuild step aborts the script with a
#     non-zero exit. The script never exits 0 without producing a valid .xcframework.
#
# Prerequisite (architectural, not environmental):
#   - The current `SunbayCheckout` product is a PURE-SwiftPM *library*, which does not
#     build as a .framework on any machine -- archiving it yields a raw object file (or a
#     static library), never a .framework bundle. A different environment will NOT make
#     this script produce an artifact as-is. Producing any binary therefore REQUIRES
#     first wrapping the SPM product in a framework target (the C3 step). See
#     docs/releasing.md. Until that wrapper exists, the discovery gate below fails loudly.

SCHEME="SunbayCheckout"
BUILD_DIR="build"
DEVICE_ARCHIVE="${BUILD_DIR}/SunbayCheckout-iOS.xcarchive"
SIMULATOR_ARCHIVE="${BUILD_DIR}/SunbayCheckout-iOS-Simulator.xcarchive"
XCFRAMEWORK="${BUILD_DIR}/SunbayCheckout.xcframework"

# Resolve to the repo root (this script lives in <repo>/scripts).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

echo "==> Preparing clean build directory"
mkdir -p "${BUILD_DIR}"
# Remove prior archives and xcframework so re-runs are deterministic.
rm -rf "${DEVICE_ARCHIVE}" "${SIMULATOR_ARCHIVE}" "${XCFRAMEWORK}"

echo "==> Archiving ${SCHEME} for device (generic/platform=iOS)"
xcodebuild archive \
  -scheme "${SCHEME}" \
  -destination 'generic/platform=iOS' \
  -archivePath "${DEVICE_ARCHIVE}" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES

echo "==> Archiving ${SCHEME} for simulator (generic/platform=iOS Simulator)"
xcodebuild archive \
  -scheme "${SCHEME}" \
  -destination 'generic/platform=iOS Simulator' \
  -archivePath "${SIMULATOR_ARCHIVE}" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES

# Locate the built framework in each archive. A SwiftPM library scheme archived with
# BUILD_LIBRARY_FOR_DISTRIBUTION=YES places a .framework under
# <archive>/Products/Library/Frameworks/. We discover it rather than hardcode so the
# script adapts to the exact product name xcodebuild emits.
find_framework() {
  local archive="$1"
  find "${archive}/Products" -type d -name '*.framework' 2>/dev/null | head -n 1
}

DEVICE_FRAMEWORK="$(find_framework "${DEVICE_ARCHIVE}")"
SIMULATOR_FRAMEWORK="$(find_framework "${SIMULATOR_ARCHIVE}")"

if [[ -z "${DEVICE_FRAMEWORK}" || -z "${SIMULATOR_FRAMEWORK}" ]]; then
  echo "ERROR: archiving succeeded but produced no .framework to feed -create-xcframework." >&2
  echo "  device archive:    ${DEVICE_ARCHIVE} -> '${DEVICE_FRAMEWORK}'" >&2
  echo "  simulator archive: ${SIMULATOR_ARCHIVE} -> '${SIMULATOR_FRAMEWORK}'" >&2
  echo >&2
  echo "This is an architectural property of a PURE-SwiftPM *library* scheme, not a" >&2
  echo "toolchain/environment quirk: archiving such a product produces no consumable" >&2
  echo ".framework (e.g. only a raw object file or a static library), on any machine." >&2
  echo "A different environment will NOT make this succeed as-is. Producing a" >&2
  echo "distributable framework REQUIRES wrapping the SPM product in a framework target" >&2
  echo "(e.g. a Tuist/Xcode framework project) before -create-xcframework can consume it." >&2
  echo "See docs/releasing.md (future C3 path)." >&2
  echo >&2
  echo "Products tree(s) for diagnosis:" >&2
  find "${DEVICE_ARCHIVE}/Products" 2>/dev/null >&2 || true
  find "${SIMULATOR_ARCHIVE}/Products" 2>/dev/null >&2 || true
  exit 1
fi

echo "==> Creating XCFramework"
echo "    device:    ${DEVICE_FRAMEWORK}"
echo "    simulator: ${SIMULATOR_FRAMEWORK}"
# Note: -create-xcframework also supports a `-library <path> -headers <path>` form for
# static-library products; a C3 implementer should evaluate -framework vs -library.
xcodebuild -create-xcframework \
  -framework "${DEVICE_FRAMEWORK}" \
  -framework "${SIMULATOR_FRAMEWORK}" \
  -output "${XCFRAMEWORK}"

echo "==> Done: ${XCFRAMEWORK}"
ls "${XCFRAMEWORK}"
