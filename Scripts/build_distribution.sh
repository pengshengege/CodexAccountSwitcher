#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_ROOT="${PROJECT_DIR}/.build-distribution"
RELEASE_DIR="${PROJECT_DIR}/dist/release"
INFO_PLIST="${PROJECT_DIR}/Resources/Info.plist"
APP_NAME="Codex Account Switcher"
EXECUTABLE_NAME="CodexAccountSwitcher"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
FINAL_APP="${RELEASE_DIR}/${APP_NAME}.app"
FINAL_DMG="${RELEASE_DIR}/${APP_NAME} v${VERSION} Universal.dmg"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-account-switcher-release.XXXXXX")"
STAGED_APP="${STAGING_ROOT}/${APP_NAME}.app"
DMG_SOURCE="${STAGING_ROOT}/dmg"
TEMP_DMG="${STAGING_ROOT}/${APP_NAME}.dmg"

cleanup() {
    if [[ -d "${STAGING_ROOT}" ]]; then
        find "${STAGING_ROOT}" -depth -delete
    fi
}
trap cleanup EXIT

if [[ -z "${SIGNING_IDENTITY}" ]]; then
    echo "Set DEVELOPER_ID_APPLICATION to a Developer ID Application certificate name." >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"${SIGNING_IDENTITY}\""; then
    echo "Missing signing identity: ${SIGNING_IDENTITY}" >&2
    exit 1
fi

plutil -lint "${INFO_PLIST}" >/dev/null

for architecture in arm64 x86_64; do
    swift build \
        --configuration release \
        --package-path "${PROJECT_DIR}" \
        --scratch-path "${BUILD_ROOT}/${architecture}" \
        --triple "${architecture}-apple-macosx13.0"
done

ARM_BIN_DIR="$(swift build \
    --configuration release \
    --package-path "${PROJECT_DIR}" \
    --scratch-path "${BUILD_ROOT}/arm64" \
    --triple arm64-apple-macosx13.0 \
    --show-bin-path)"

X86_BIN_DIR="$(swift build \
    --configuration release \
    --package-path "${PROJECT_DIR}" \
    --scratch-path "${BUILD_ROOT}/x86_64" \
    --triple x86_64-apple-macosx13.0 \
    --show-bin-path)"

mkdir -p "${STAGED_APP}/Contents/MacOS"
mkdir -p "${STAGED_APP}/Contents/Resources"
cp "${INFO_PLIST}" "${STAGED_APP}/Contents/Info.plist"
lipo -create \
    "${ARM_BIN_DIR}/${EXECUTABLE_NAME}" \
    "${X86_BIN_DIR}/${EXECUTABLE_NAME}" \
    -output "${STAGED_APP}/Contents/MacOS/${EXECUTABLE_NAME}"
chmod 755 "${STAGED_APP}/Contents/MacOS/${EXECUTABLE_NAME}"

codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "${SIGNING_IDENTITY}" \
    "${STAGED_APP}"

codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"
test "$(lipo -archs "${STAGED_APP}/Contents/MacOS/${EXECUTABLE_NAME}")" = "x86_64 arm64" || \
    test "$(lipo -archs "${STAGED_APP}/Contents/MacOS/${EXECUTABLE_NAME}")" = "arm64 x86_64"

mkdir -p "${RELEASE_DIR}"
if [[ -e "${FINAL_APP}" ]]; then
    find "${FINAL_APP}" -depth -delete
fi
ditto "${STAGED_APP}" "${FINAL_APP}"

mkdir -p "${DMG_SOURCE}"
ditto "${STAGED_APP}" "${DMG_SOURCE}/${APP_NAME}.app"
ln -s /Applications "${DMG_SOURCE}/Applications"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_SOURCE}" \
    -format UDZO \
    -ov \
    "${TEMP_DMG}"

codesign \
    --force \
    --timestamp \
    --sign "${SIGNING_IDENTITY}" \
    "${TEMP_DMG}"

if [[ -n "${NOTARY_PROFILE}" ]]; then
    xcrun notarytool submit \
        "${TEMP_DMG}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait
    xcrun stapler staple "${TEMP_DMG}"
    xcrun stapler validate "${TEMP_DMG}"
    xcrun stapler staple "${FINAL_APP}"
    xcrun stapler validate "${FINAL_APP}"
fi

ditto "${TEMP_DMG}" "${FINAL_DMG}"
hdiutil verify "${FINAL_DMG}"

echo "Built app: ${FINAL_APP}"
echo "Built DMG: ${FINAL_DMG}"
if [[ -z "${NOTARY_PROFILE}" ]]; then
    echo "Notarization skipped. Set NOTARY_PROFILE to a notarytool keychain profile to submit and staple."
fi
