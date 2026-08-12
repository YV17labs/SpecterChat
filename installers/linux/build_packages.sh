#!/usr/bin/env bash
# Build Linux distributables (AppImage + .deb) from the release bundle produced
# by `flutter build linux --release`. Invoked by the GitHub Actions release
# workflow, but also runnable locally on Linux.
#
# Usage: installers/linux/build_packages.sh <version>
set -euo pipefail

VERSION="${1:?usage: build_packages.sh <version>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="$ROOT/build/linux/x64/release/bundle"
DIST="$ROOT/dist"
ICON_SVG="$ROOT/assets/logo.svg"
APP="specterchat"            # binary name (BINARY_NAME in linux/CMakeLists.txt)
PRETTY="SpecterChat"
DESKTOP="$ROOT/installers/linux/$APP.desktop"

if [ ! -d "$BUNDLE" ]; then
  echo "error: release bundle not found at $BUNDLE — run 'flutter build linux --release' first" >&2
  exit 1
fi

mkdir -p "$DIST"

# ---------------------------------------------------------------------------
# AppImage
# ---------------------------------------------------------------------------
APPDIR="$ROOT/build/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/scalable/apps"

cp -r "$BUNDLE"/. "$APPDIR/usr/bin/"
cp "$DESKTOP"   "$APPDIR/usr/share/applications/$APP.desktop"
cp "$DESKTOP"   "$APPDIR/$APP.desktop"                                   # root copy for appimagetool
cp "$ICON_SVG"  "$APPDIR/usr/share/icons/hicolor/scalable/apps/$APP.svg"
cp "$ICON_SVG"  "$APPDIR/$APP.svg"                                       # root icon (matches Icon=)

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/specterchat" "$@"
EOF
chmod +x "$APPDIR/AppRun"

TOOL="$ROOT/build/appimagetool-x86_64.AppImage"
if [ ! -x "$TOOL" ]; then
  curl -fsSL -o "$TOOL" \
    "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod +x "$TOOL"
fi
# APPIMAGE_EXTRACT_AND_RUN avoids needing FUSE on CI runners.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" \
  "$APPDIR" "$DIST/$PRETTY-$VERSION-linux-x86_64.AppImage"

# ---------------------------------------------------------------------------
# .deb
# ---------------------------------------------------------------------------
PKG="$ROOT/build/deb"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" \
         "$PKG/opt/$PRETTY" \
         "$PKG/usr/bin" \
         "$PKG/usr/share/applications" \
         "$PKG/usr/share/icons/hicolor/scalable/apps"

cp -r "$BUNDLE"/. "$PKG/opt/$PRETTY/"
ln -s "/opt/$PRETTY/$APP" "$PKG/usr/bin/$APP"
cp "$DESKTOP"  "$PKG/usr/share/applications/$APP.desktop"
cp "$ICON_SVG" "$PKG/usr/share/icons/hicolor/scalable/apps/$APP.svg"

cat > "$PKG/DEBIAN/control" <<EOF
Package: specterchat
Version: $VERSION
Section: net
Priority: optional
Architecture: amd64
Depends: libgtk-3-0
Maintainer: Yoann Vanitou (YV17labs) <yoann@yv17labs.com>
Homepage: https://www.yv17labs.com
Description: Lightweight cross-platform MCP chat client
 SpecterChat connects to any OpenAI-compatible API and to MCP servers,
 rendering tool results (including images) inline and forwarding them
 back to the model.
EOF

dpkg-deb --build --root-owner-group "$PKG" "$DIST/$PRETTY-$VERSION-linux-amd64.deb"

echo "Built artifacts:"
ls -la "$DIST"
