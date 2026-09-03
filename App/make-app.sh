#!/bin/bash
#
# Builds AnkiFlow.app -- a real double-clickable Mac app bundle with its icon,
# which is what you need for /Applications and the Dock. `swift run` only
# produces a bare executable, which macOS won't treat as an app.
#
#   ./make-app.sh              build the bundle here
#   ./make-app.sh --install    build it and move it into /Applications
#
set -euo pipefail

APP_NAME="AnkiFlow"
BUNDLE_ID="com.tasawwar.ankiflow"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# Recorded in the bundle so Help > Update from Source knows where this copy was
# built from. The build script is standing in the checkout, so it knows the
# answer for free -- the app would otherwise have to ask you.
SOURCE_ROOT="$(cd "$HERE/.." && pwd)"

# --- version ----------------------------------------------------------------
# The git tag is the single source of truth. Nothing is typed twice, so the
# bundle can never claim a version the repository disagrees with -- which is
# the failure mode of a hardcoded VERSION="1.0" that somebody forgets to bump.
#
#   CFBundleShortVersionString  the release:            1.2
#   AFBuild                     exactly what was built: 1.2-3-gabc1234-dirty
#
# That second string is what makes a bug report actionable. It says "three
# commits past v1.2, with uncommitted changes", which "1.2" never could.
if git -C "$SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  NEAREST_TAG="$(git -C "$SOURCE_ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
  BUILD_ID="$(git -C "$SOURCE_ROOT" describe --tags --dirty --always 2>/dev/null || true)"
else
  NEAREST_TAG=""
  BUILD_ID=""
fi

# Tags are written v1.2 by convention; Info.plist wants digits and dots.
VERSION="${NEAREST_TAG#v}"
BUILD_ID="${BUILD_ID#v}"

if [ -z "$VERSION" ]; then
  VERSION="0.0.0"
  echo "    (no git tag yet -- version 0.0.0)"
  echo "    (tag your first release with:  git tag -a v1.0 -m \"First release\")"
fi
[ -n "$BUILD_ID" ] || BUILD_ID="$VERSION"

echo "==> Version $VERSION  (build $BUILD_ID)"

if ! command -v swift >/dev/null 2>&1; then
  echo "No Swift toolchain found."
  echo "Install Xcode from the App Store, or run:  xcode-select --install"
  exit 1
fi

echo "==> Building (release)…"
swift build -c release

BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -f "$BINARY" ]; then
  echo "Build finished but no binary at $BINARY"
  exit 1
fi

APP="$HERE/$APP_NAME.app"
echo "==> Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# --- icon -------------------------------------------------------------------
# iconutil wants a .iconset folder, and the asset catalogue PNGs already use
# exactly the filenames it expects -- so just copy them across.
ICONSET_SOURCE="$HERE/Resources/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICONSET_SOURCE" ]; then
  echo "==> Building icon…"
  TMP_ICONSET="$(mktemp -d)/$APP_NAME.iconset"
  mkdir -p "$TMP_ICONSET"
  cp "$ICONSET_SOURCE"/icon_*.png "$TMP_ICONSET/"
  iconutil -c icns "$TMP_ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"
  rm -rf "$(dirname "$TMP_ICONSET")"
else
  echo "    (no icon assets found at $ICONSET_SOURCE -- building without an icon)"
fi

# --- Info.plist -------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>              <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>AFBuild</key>                       <string>$BUILD_ID</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>AFSourcePath</key>                  <string>$SOURCE_ROOT</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>      <string>PDF</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# --- sign -------------------------------------------------------------------
# Ad-hoc signature. Enough for an app you build and run yourself; it is not a
# Developer ID signature and cannot be distributed to other machines.
echo "==> Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "    (codesign unavailable -- the app will still run on this Mac)"

# Not sandboxed, on purpose: the app needs to read whatever lecture folder you
# point it at and write sidecar files beside your PDFs.

if [ "${1:-}" = "--install" ]; then
  # Replacing a bundle while it's running leaves the old copy in memory and can
  # confuse the Dock, so close it first.
  WAS_RUNNING=no
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    WAS_RUNNING=yes
    echo "==> Quitting the running copy…"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
      sleep 0.3
    done
    pkill -x "$APP_NAME" 2>/dev/null || true
  fi

  echo "==> Installing to /Applications…"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  rm -rf "$APP"

  # The Dock caches icons aggressively; nudge it so a changed icon shows up.
  touch "/Applications/$APP_NAME.app"

  echo
  echo "Done. $APP_NAME is in your Applications folder."
  if [ "$WAS_RUNNING" = "yes" ]; then
    echo "Relaunching…"
    open "/Applications/$APP_NAME.app"
  else
    echo "Open it, then right-click its Dock icon ▸ Options ▸ Keep in Dock."
    open -R "/Applications/$APP_NAME.app"
  fi
else
  echo
  echo "Done: $APP"
  echo "Drag it to Applications, or re-run with --install to do that for you."
  open -R "$APP"
fi
