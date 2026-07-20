#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/.build-app"
DIST_DIR="${PROJECT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/Codex Account Switcher.app"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-account-switcher.XXXXXX")"
STAGED_APP="${STAGING_DIR}/Codex Account Switcher.app"

cleanup() {
    rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

swift build \
    --configuration release \
    --package-path "${PROJECT_DIR}" \
    --scratch-path "${BUILD_DIR}"

BIN_DIR="$(swift build \
    --configuration release \
    --package-path "${PROJECT_DIR}" \
    --scratch-path "${BUILD_DIR}" \
    --show-bin-path)"

mkdir -p "${STAGED_APP}/Contents/MacOS"
mkdir -p "${STAGED_APP}/Contents/Resources"
cp "${BIN_DIR}/CodexAccountSwitcher" "${STAGED_APP}/Contents/MacOS/"
cp "${PROJECT_DIR}/Resources/Info.plist" "${STAGED_APP}/Contents/Info.plist"
chmod 755 "${STAGED_APP}/Contents/MacOS/CodexAccountSwitcher"

codesign \
    --force \
    --deep \
    --sign - \
    --identifier "com.local.CodexAccountSwitcher" \
    "${STAGED_APP}"

mkdir -p "${DIST_DIR}"
if [[ -e "${APP_BUNDLE}" ]]; then
    rm -rf "${APP_BUNDLE}"
fi
mv "${STAGED_APP}" "${APP_BUNDLE}"

echo "Built: ${APP_BUNDLE}"
