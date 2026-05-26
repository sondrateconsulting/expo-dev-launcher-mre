#!/usr/bin/env bash
#
# Demonstrates that expo-dev-launcher's "Strip Local Network Keys for Release"
# build phase has inputPaths but no outputPaths, which causes Xcode 26 to abort
# the archive with "Cycle inside <target>".
#
# Run this after `npm install && npx expo prebuild --platform ios`.
#
set -euo pipefail

PBXPROJ="ios/expodevlaunchermre.xcodeproj/project.pbxproj"
if [ ! -f "$PBXPROJ" ]; then
  echo "Error: $PBXPROJ not found. Run: npm install && npx expo prebuild --platform ios" >&2
  exit 1
fi

echo "=== Build phase as emitted by expo-dev-launcher ==="
echo
grep -A14 "Strip Local Network Keys for Release \*/ = {" "$PBXPROJ" \
  | sed -n '/PBXShellScriptBuildPhase/,/shellPath/p'

echo
echo "=== Outputs check ==="
# Pull just the outputPaths block under the Strip phase
phase_block=$(awk '/Strip Local Network Keys for Release \*\/ = \{/,/^\t\t\};$/' "$PBXPROJ")
output_count=$(echo "$phase_block" \
  | awk '/outputPaths = \(/,/\);/' \
  | grep -c '"' || true)

if [ "$output_count" -eq 0 ]; then
  echo "BUG CONFIRMED: outputPaths is empty."
  echo "Xcode 26's stricter dependency analyzer treats this as a cycle"
  echo "because the script mutates Info.plist (declared as input) without"
  echo "declaring it as an output."
  exit 1
else
  echo "outputPaths has $output_count entries. Bug is fixed."
fi
