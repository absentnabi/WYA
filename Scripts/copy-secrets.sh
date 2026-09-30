#!/bin/bash
# Copies Secrets.plist into the app bundle. Falls back to the example file so
# the project builds with sample arrivals when no keys have been added.
set -euo pipefail
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "${DEST}"
if [[ -f "${SRCROOT}/Secrets.plist" ]]; then
  cp "${SRCROOT}/Secrets.plist" "${DEST}/Secrets.plist"
else
  cp "${SRCROOT}/Secrets.example.plist" "${DEST}/Secrets.plist"
fi
