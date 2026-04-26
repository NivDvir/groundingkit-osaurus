#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build + zip the Osaurus plugin distribution package.
#
# Output: dist/dev.nivdvir.GroundingKit-<version>.zip
#
# Contents (per Osaurus PLUGIN_AUTHORING.md install layout):
#   libgroundingkit-osaurus.dylib
#   mlx-swift_Cmlx.bundle/                 ← Metal kernels (REQUIRED for MLX runtime)
#   SKILL.md                               ← agentskills.io frontmatter (loaded by Osaurus)
#   README.md
#   LICENSE
#   osaurus-plugin.json
#
# Build tool: xcodebuild (NOT swift build).
# Reason: mlx-swift's Package.swift relies on Xcode's auto-discovery of `.metal`
# files to compile + bundle `default.metallib`. SwiftPM has no equivalent build
# phase, so a `swift build`-produced dylib has no metallib at runtime and MLX
# inference hangs forever (see docs/architecture-internals.html).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

# Read plugin id + version from osaurus-plugin.json (single source of truth)
PLUGIN_ID=$(jq -r '.plugin_id' osaurus-plugin.json)
VERSION=$(jq -r '.version' osaurus-plugin.json)
ZIP_NAME="${PLUGIN_ID}-${VERSION}.zip"

echo "═══ Building ${PLUGIN_ID} v${VERSION} ═══"

# 1. Build the dylib via xcodebuild (handles Metal compilation + bundling)
echo "→ xcodebuild -scheme groundingkit-osaurus -configuration Release"
xcodebuild \
    -scheme groundingkit-osaurus \
    -configuration Release \
    -destination 'platform=macOS' \
    build > /tmp/gk-osaurus-xcodebuild.log 2>&1 \
  || { echo "ERROR: xcodebuild failed — see /tmp/gk-osaurus-xcodebuild.log"; exit 1; }

# Locate xcodebuild's DerivedData output directory.
# xcodebuild -showBuildSettings does not work for standalone Swift packages (no .xcodeproj).
# Instead, find the DerivedData folder whose name starts with the package name.
XC_DERIVED=$(find "${HOME}/Library/Developer/Xcode/DerivedData" -maxdepth 1 -name 'groundingkit-osaurus-*' -type d | sort | tail -1)
XC_PRODUCTS="${XC_DERIVED}/Build/Products/Release"
if [[ -z "${XC_DERIVED}" || ! -d "${XC_PRODUCTS}" ]]; then
    echo "ERROR: could not locate xcodebuild BUILT_PRODUCTS_DIR (looked in ~/Library/Developer/Xcode/DerivedData/groundingkit-osaurus-*)"
    exit 1
fi
echo "→ DerivedData: ${XC_DERIVED}"  

DYLIB_SRC="${XC_PRODUCTS}/PackageFrameworks/groundingkit-osaurus.framework/Versions/A/groundingkit-osaurus"
METALLIB_SRC="${XC_PRODUCTS}/mlx-swift_Cmlx.bundle"

if [[ ! -f "${DYLIB_SRC}" ]]; then
    echo "ERROR: dylib not found at ${DYLIB_SRC}"
    exit 1
fi
if [[ ! -d "${METALLIB_SRC}" ]]; then
    echo "ERROR: metallib bundle not found at ${METALLIB_SRC}"
    exit 1
fi

# 2. Verify entry symbol is exported
echo "→ verifying osaurus_plugin_entry symbol"
if ! nm -gU "${DYLIB_SRC}" | grep -q "_osaurus_plugin_entry"; then
    echo "ERROR: _osaurus_plugin_entry symbol missing from dylib"
    exit 1
fi

echo "→ dylib:    ${DYLIB_SRC}"
echo "→ metallib: ${METALLIB_SRC}"

# 3. Stage the package
STAGE="dist/${PLUGIN_ID}-${VERSION}"
rm -rf "${STAGE}" "dist/${ZIP_NAME}"
mkdir -p "${STAGE}"

# Copy dylib under its expected runtime name (`lib<product>.dylib`)
cp "${DYLIB_SRC}" "${STAGE}/libgroundingkit-osaurus.dylib"
cp -R "${METALLIB_SRC}" "${STAGE}/"
cp SKILL.md README.md LICENSE osaurus-plugin.json "${STAGE}/"

# 4. Zip
echo "→ zipping → dist/${ZIP_NAME}"
( cd dist && zip -qr "${ZIP_NAME}" "${PLUGIN_ID}-${VERSION}" )

# 5. Report
SIZE=$(du -h "dist/${ZIP_NAME}" | cut -f1)
echo ""
echo "✓ Built dist/${ZIP_NAME} (${SIZE})"
echo ""
echo "Local install:"
echo "  mkdir -p ~/.osaurus/Tools/${PLUGIN_ID}/${VERSION}"
echo "  unzip -o dist/${ZIP_NAME} -d ~/.osaurus/Tools/"
