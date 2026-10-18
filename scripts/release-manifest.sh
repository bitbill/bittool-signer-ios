#!/bin/sh
# Writes the verification manifest for a release.
#
#     scripts/release-manifest.sh [output-directory]
#
# It records what a third party needs in order to check that a published build
# was made from published source: the commit, the hash of every tracked file,
# and the engine bundle hash -- rebuilt from a clean dependency install in a
# throwaway copy of the commit, so the recorded hash is one that reproduces
# rather than one that merely happens to be on this disk.
#
# The working tree must be clean. A manifest describing uncommitted edits would
# name a commit nobody else can check out.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/release"}
BUNDLE=BitToolSigner/Resources/signer.js

cd "$ROOT"
if [ -n "$(git status --porcelain)" ]; then
  echo "The working tree has uncommitted changes. Commit them first." >&2
  exit 1
fi
COMMIT=$(git rev-parse HEAD)
mkdir -p "$OUT"

# Every tracked file, hashed in a fixed order, so two people comparing two
# manifests compare the same list in the same sequence.
git ls-files -z | sort -z | xargs -0 shasum -a 256 > "$OUT/SHA256SUMS.txt"
MANIFEST_HASH=$(shasum -a 256 "$OUT/SHA256SUMS.txt" | cut -d' ' -f1)
SHIPPED=$(shasum -a 256 "$BUNDLE" | cut -d' ' -f1)
FILES=$(git ls-files | wc -l | tr -d ' ')
# The Info.plist is generated at build time, so the version lives in the project.
VERSION=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' BitToolSigner.xcodeproj/project.pbxproj | head -1)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' BitToolSigner.xcodeproj/project.pbxproj | head -1)

# Rebuild the engine from this exact commit in a scratch copy. `npm ci` installs
# the locked versions and `--ignore-scripts` keeps a dependency's install hook
# from touching the result.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
git archive --format=tar "$COMMIT" | tar -x -C "$WORK"
( cd "$WORK/engine" && npm ci --ignore-scripts >"$OUT/clean-install.log" 2>&1 && npm run build >"$OUT/clean-build.log" 2>&1 )
REBUILT=$(shasum -a 256 "$WORK/$BUNDLE" | cut -d' ' -f1)

REPRODUCED=false
[ "$SHIPPED" = "$REBUILT" ] && REPRODUCED=true

cat > "$OUT/release-manifest.json" <<JSON
{
  "product": "BitTool Signer",
  "version": "$VERSION",
  "build": "$BUILD",
  "commit": "$COMMIT",
  "trackedFiles": $FILES,
  "trackedManifestSHA256": "$MANIFEST_HASH",
  "engineBundle": {
    "path": "$BUNDLE",
    "shippedSHA256": "$SHIPPED",
    "rebuiltSHA256": "$REBUILT",
    "reproduced": $REPRODUCED,
    "node": "$(node --version)",
    "npm": "$(npm --version)"
  }
}
JSON

echo "commit     $COMMIT"
echo "files      $FILES (manifest $MANIFEST_HASH)"
echo "signer.js  $SHIPPED"
if [ "$REPRODUCED" = true ]; then
  echo "rebuild    reproduces it exactly"
else
  echo "rebuild    DIFFERS: $REBUILT" >&2
  exit 1
fi
echo "written to $OUT"
