#!/bin/sh
# Regenerates the site's derived assets. There is no build step for the site
# itself — this is a one-off you re-run when the source art changes.
#
#   sh assets/build-assets.sh
#
# Requires: Google Chrome, cwebp (brew install webp), sips (macOS built-in).
set -e
cd "$(dirname "$0")/.."

STORE="../splitzy/store/screenshots_v2"

# 1. Store slides → gallery images. Source is 1320x2868 PNG (~300 KB each);
#    downscaled to 660x1434 and encoded as WebP they total ~670 KB for all ten.
if [ -d "$STORE/png" ]; then
  mkdir -p assets/shots
  for f in "$STORE"/png/*.png; do
    n=$(basename "$f" .png)
    cp "$f" "/tmp/$n.png"
    sips -Z 1434 "/tmp/$n.png" >/dev/null
    cwebp -q 82 -m 6 -sharp_yuv "/tmp/$n.png" -o "assets/shots/$n.webp" >/dev/null
    rm -f "/tmp/$n.png"
  done
fi

# 2. Poppins 400-900 (latin + latin-ext), vendored from the store sources so the
#    site and the store screenshots use identical files.
if [ -d "$STORE/src/fonts" ]; then
  mkdir -p assets/fonts
  cp "$STORE"/src/fonts/poppins-*.woff2 assets/fonts/
fi

# 3. Icon variants from assets/app-icon.png (512x512, the source of truth).
cwebp -q 88 -m 6 assets/app-icon.png -o assets/app-icon.webp >/dev/null
cp assets/app-icon.png assets/apple-touch-icon.png
sips -Z 180 assets/apple-touch-icon.png >/dev/null

# 4. Open Graph card, rendered from assets/og-src/og.html at 1200x630.
#    Needs the site served locally so the card can load /style.css.
python3 -m http.server 8777 >/dev/null 2>&1 &
SERVER=$!
sleep 1
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless --disable-gpu --hide-scrollbars --force-color-profile=srgb \
  --window-size=1200,630 --screenshot=assets/og.png \
  http://localhost:8777/assets/og-src/og.html >/dev/null 2>&1
kill $SERVER

echo "Assets rebuilt."
