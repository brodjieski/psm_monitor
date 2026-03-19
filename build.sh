#!/bin/bash

# Title       : build.sh
# Description : Build the psm_monitor installer package using pkgbuild
# Usage       : ./build.sh [version]
#               Version defaults to 1.0 if not provided.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — customize for your organization
# ---------------------------------------------------------------------------
IDENTIFIER="com.organization.psm-monitor"
VERSION="${1:-1.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PKGSOURCE_DIR="${SCRIPT_DIR}/pkgsource"
PAYLOAD_ROOT="${SCRIPT_DIR}/pkg/root"
SCRIPTS_DIR="${SCRIPT_DIR}/pkg/scripts"
OUTPUT_DIR="${SCRIPT_DIR}/output"
PKG_NAME="psm_monitor-${VERSION}.pkg"

# ---------------------------------------------------------------------------
# Stage payload files into the root directory
# ---------------------------------------------------------------------------
echo "Staging payload..."

mkdir -p "${PAYLOAD_ROOT}/Library/LaunchDaemons/"
mkdir -p "${PAYLOAD_ROOT}/usr/local/bin/"

# LaunchDaemon plist

cp "${PKGSOURCE_DIR}/com.organization.psm-monitor.plist" \
   "${PAYLOAD_ROOT}/Library/LaunchDaemons/${IDENTIFIER}.plist"

sed -i '' "s/com.organization.psm-monitor/$IDENTIFIER/g" "${PAYLOAD_ROOT}/Library/LaunchDaemons/${IDENTIFIER}.plist"

# Collection script
cp "${SCRIPT_DIR}/psm_monitor.zsh" \
   "${PAYLOAD_ROOT}/usr/local/bin/psm_monitor.zsh"

# ---------------------------------------------------------------------------
# Configure pre/postinstall scripts and ensure they are executable
# ---------------------------------------------------------------------------
mkdir -p "${SCRIPTS_DIR}/"

cp "${PKGSOURCE_DIR}/postinstall" \
   "${SCRIPTS_DIR}/"
cp "${PKGSOURCE_DIR}/preinstall" \
   "${SCRIPTS_DIR}/"
   
sed -i '' "s/^DAEMON_LABEL.*/DAEMON_LABEL=\"$IDENTIFIER\"/g" "${SCRIPTS_DIR}/preinstall"
sed -i '' "s/^DAEMON_LABEL.*/DAEMON_LABEL=\"$IDENTIFIER\"/g" "${SCRIPTS_DIR}/postinstall"

chmod +x "${SCRIPTS_DIR}/preinstall"
chmod +x "${SCRIPTS_DIR}/postinstall"

# ---------------------------------------------------------------------------
# Build the package
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"

echo "Building ${PKG_NAME}..."
pkgbuild \
    --root        "${PAYLOAD_ROOT}" \
    --scripts     "${SCRIPTS_DIR}" \
    --identifier  "${IDENTIFIER}" \
    --version     "${VERSION}" \
    --ownership   recommended \
    "${OUTPUT_DIR}/${PKG_NAME}"

echo ""
echo "Package written to: ${OUTPUT_DIR}/${PKG_NAME}"
