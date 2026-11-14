#!/bin/zsh
# Build SpaceManager.app (the sm front) and the `sm` CLI into .build/.
# Usage: scripts/package-app.sh [release|debug]   → prints the bundle path; the CLI is .build/<config>/sm
set -euo pipefail

configuration="${1:-release}"
repository_root="${0:A:h:h}"
bundle="$repository_root/.build/SpaceManager.app"
products="$repository_root/.build/$configuration"

cd "$repository_root"
swift build -c "$configuration"

# Screen Recording and Accessibility grants follow the signature. An Apple Development certificate keeps them
# across rebuilds; without one this falls back to ad-hoc, and macOS asks again after each install.
# SM_SIGN_IDENTITY overrides.
identity="${SM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
identity="${identity:--}"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$products/SpaceManager" "$bundle/Contents/MacOS/SpaceManager"
cp "$repository_root/App/Info.plist" "$bundle/Contents/Info.plist"
cp "$repository_root/Assets/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
codesign --force -s "$identity" "$bundle"

echo "$bundle"
