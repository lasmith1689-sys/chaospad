#!/bin/bash
# Builds and uploads ChaosPad's Apple-hosted asset pack: the trimmed Splinter Cell Chaos Theory disc image (sc3.sparse, made
# on my PC by runtime/scripts/mksparse.py: the disc without the French and Spanish voices and the online-only files) as the
# essential pack sc3disc, which the system downloads together with the app (iOS 26 Background Assets).
# The image arrives as encrypted chunks (release disc-input, key in GAME_KEY), is decrypted only inside the runner, checked
# against sparse.sha256, packaged with ba-package and uploaded with altool.
#
# Usage: asset-packs.sh WORK_DIR
# Environment: GH_TOKEN, GITHUB_REPOSITORY, GAME_KEY, ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, CHAOSPAD_APPLE_ID
set -euo pipefail

mkdir -p "$1"
work=$(cd "$1" && pwd)
apple_id=${CHAOSPAD_APPLE_ID:?}
pack=sc3disc
file=sc3.sparse
openssl=/opt/homebrew/opt/openssl@3/bin/openssl
[ -x "$openssl" ] || openssl=openssl

# the App Store Connect API key where altool looks for it
keys="$HOME/.appstoreconnect/private_keys"
mkdir -p "$keys"
p8=$(printf '%s' "$ASC_KEY_P8" | tr -d '\r')
if [[ "$p8" != *"BEGIN PRIVATE KEY"* ]]; then
  p8=$(printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----' "$(printf '%s' "$p8" | tr -d ' \n' | fold -w 64)")
fi
(umask 077 && printf '%s\n' "$p8" > "$keys/AuthKey_$ASC_KEY_ID.p8")
unset p8
trap 'rm -rf "$keys/AuthKey_$ASC_KEY_ID.p8" "$work/disc"' EXIT

cd "$work"
gh release download disc-input -R "$GITHUB_REPOSITORY" -p sparse.sha256 -D "$work" --clobber
echo "▶ $pack: $file"
rm -rf disc && mkdir disc
for chunk in $(gh release view disc-input -R "$GITHUB_REPOSITORY" --json assets --jq ".assets[].name | select(startswith(\"$file.part\"))" | sort); do
  gh release download disc-input -R "$GITHUB_REPOSITORY" -p "$chunk" -D "$work" --clobber
  "$openssl" enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -pass env:GAME_KEY -in "$chunk" >> "disc/$file"
  rm -f "$chunk"
  echo "  $chunk -> $(stat -f %z "disc/$file") bytes"
done
expected=$(awk '{print $1}' sparse.sha256)
actual=$(shasum -a 256 "disc/$file" | awk '{print $1}')
[ "$expected" = "$actual" ] || { echo "::error::$file checksum mismatch ($actual, expected $expected)"; exit 1; }
cat > "$pack.json" <<EOF
{
  "assetPackID": "$pack",
  "downloadPolicy": { "essential": { "installationEventTypes": ["firstInstallation", "subsequentUpdate"] } },
  "fileSelectors": [ { "file": "$file" } ],
  "platforms": ["iOS"]
}
EOF
start=$SECONDS
(cd disc && xcrun ba-package "$work/$pack.json" -o "$work/$pack.aar")
rm -f "disc/$file"
echo "  packaged in $((SECONDS - start)) s: $(stat -f %z "$pack.aar") bytes"
xcrun altool --upload-asset-pack "$pack.aar" --apple-id "$apple_id" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format normal
rm -f "$pack.aar"
# processing ends in READY_FOR_TESTING (success) or FAILED (altool --wait never returns for READY_FOR_TESTING)
for attempt in $(seq 1 120); do
  versions=$(xcrun altool --list-asset-pack-versions --apple-id "$apple_id" --asset-pack-identifier "$pack" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format normal 2>&1 || true)
  if grep -q "FAILED" <<<"$versions"; then echo "$versions"; echo "::error::$pack processing failed"; exit 1; fi
  if grep -q "READY_FOR_TESTING\|READY_FOR_INTERNAL_TESTING" <<<"$versions"; then echo "$versions" | tail -n 8; break; fi
  [ "$attempt" = 120 ] && { echo "$versions"; echo "::warning::$pack still processing after an hour"; }
  sleep 30
done
xcrun altool --list-asset-packs --apple-id "$apple_id" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" || true
