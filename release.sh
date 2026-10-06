#!/bin/bash
# Builds, signs and notarizes Awake, then makes a signed, notarized DMG and a local Homebrew cask.
#   ./release.sh                  requires a Developer ID identity and a notary keychain profile
#   ./release.sh --skip-notarize  checks the build and packaging with any signing identity; makes
#                                 Awake-<version>-unnotarized.dmg and no cask
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
project="$here/Awake.xcodeproj"
dist="$here/dist"
derived="$dist/DerivedData"
team="${AWAKE_TEAM_ID:-KSF29ZC99W}"
profile="${AWAKE_NOTARY_PROFILE:-notary}"
notary_auth=(--keychain-profile "$profile")
identity="${AWAKE_SIGN_IDENTITY:-}"
sparkle_bin="${AWAKE_SPARKLE_BIN:-}"
update_account="${AWAKE_UPDATE_KEY_ACCOUNT:-io.github.theyluvenething.awake}"
app_id=io.github.theyluvenething.awake
skip_notarize=false
mounted=false

fail() {
  echo "error: $*" >&2
  exit 1
}

case "$#:${1:-}" in
  0:) ;;
  1:--skip-notarize) skip_notarize=true ;;
  *) fail "usage: $0 [--skip-notarize]" ;;
esac
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail "AWAKE_TEAM_ID must be a ten-character team ID"
if ! "$skip_notarize" && [ -n "${AWAKE_NOTARY_KEY_PATH:-}" ]; then
  [ -f "$AWAKE_NOTARY_KEY_PATH" ] || fail "AWAKE_NOTARY_KEY_PATH does not exist"
  [ -n "${AWAKE_NOTARY_KEY_ID:-}" ] || fail "set AWAKE_NOTARY_KEY_ID with the API key path"
  notary_auth=(--key "$AWAKE_NOTARY_KEY_PATH" --key-id "$AWAKE_NOTARY_KEY_ID")
  if [ -n "${AWAKE_NOTARY_ISSUER:-}" ]; then notary_auth+=(--issuer "$AWAKE_NOTARY_ISSUER"); fi
fi
if ! "$skip_notarize"; then
  for tool in generate_keys sign_update; do
    [ -x "$sparkle_bin/$tool" ] || fail "set AWAKE_SPARKLE_BIN to Sparkle 2.10.0's bin directory"
  done
  update_key="$("$sparkle_bin/generate_keys" --account "$update_account" -p)"
  expected_key="$(plutil -extract SUPublicEDKey raw -o - "$here/App/Info.plist")"
  [ "$update_key" = "$expected_key" ] || fail "update signing key does not match the app's public key"
fi

# A hash selects one certificate even when another identity has a similar name.
if [ -z "$identity" ]; then
  identities="$(security find-identity -v -p codesigning)"
  matches="$(printf '%s\n' "$identities" | awk -v team="$team" '
    /"Developer ID Application: / && $0 ~ "\\(" team "\\)\"$" { print $2 }
  ')"
  count="$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n+0 }')"
  [ "$count" -ne 0 ] || fail "no valid Developer ID Application identity for team $team; set AWAKE_SIGN_IDENTITY for a --skip-notarize check"
  [ "$count" -eq 1 ] || fail "more than one Developer ID Application identity for team $team; set AWAKE_SIGN_IDENTITY to the intended certificate's hash"
  identity="$matches"
fi

echo "commit: $(git -C "$here" rev-parse HEAD)"
if [ -n "$(git -C "$here" status --porcelain -- .)" ]; then
  echo "warning: Awake has uncommitted changes" >&2
fi
if "$skip_notarize"; then
  echo "notarization and stapling skipped; this build is not a public release"
fi

# Only this script's output directory is discarded. Refuse a redirected directory.
[ ! -L "$dist" ] || fail "dist must not be a symlink"
rm -rf "$dist"
mkdir -p "$derived"
mountpoint="$dist/mounted"
cleanup() {
  if "$mounted"; then hdiutil detach "$mountpoint" >/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcodebuild -project "$project" -target Awake -configuration Release -showBuildSettings -json \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="$identity" > "$dist/build-settings.json"
version="$(plutil -extract 0.buildSettings.MARKETING_VERSION raw -o - "$dist/build-settings.json")"
build="$(plutil -extract 0.buildSettings.CURRENT_PROJECT_VERSION raw -o - "$dist/build-settings.json")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid MARKETING_VERSION: $version"
[[ "$build" =~ ^[1-9][0-9]*$ ]] || fail "invalid CURRENT_PROJECT_VERSION: $build"

xcodebuild -project "$project" -scheme Awake -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="$identity" build 2>&1 | tee "$dist/build.log"
app="$dist/Awake.app"
ditto "$derived/Build/Products/Release/Awake.app" "$app"

# Xcode signs the SPM framework's outer bundle but leaves its nested tools ad hoc signed.
# Sign the known components inside out, preserving their existing entitlements.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign_component() {
  codesign --force --sign "$identity" --options runtime --timestamp \
    --preserve-metadata=entitlements --identifier "$2" "$1"
}
sign_component "$sparkle/Versions/B/Autoupdate" org.sparkle-project.Sparkle.Autoupdate
sign_component "$sparkle/Versions/B/Updater.app" org.sparkle-project.Sparkle.Updater
sign_component "$sparkle/Versions/B/XPCServices/Downloader.xpc" org.sparkle-project.DownloaderService
sign_component "$sparkle/Versions/B/XPCServices/Installer.xpc" org.sparkle-project.InstallerLauncher
sign_component "$sparkle" org.sparkle-project.Sparkle
sign_component "$app" "$app_id"

# Inspect both slices: a valid outer bundle alone does not prove the helper is suitable.
verify_binary() {
  local binary="$1" identifier="$2" name="$3" arch details entitlements architectures
  architectures="$(lipo -archs "$binary")"
  echo "$name architectures: $architectures"
  case " $architectures " in *' arm64 '*) ;; *) fail "$name is missing arm64" ;; esac
  case " $architectures " in *' x86_64 '*) ;; *) fail "$name is missing x86_64" ;; esac
  for arch in arm64 x86_64; do
    details="$(codesign -dvv --arch "$arch" "$binary" 2>&1)"
    printf '%s\n' "$details"
    printf '%s\n' "$details" | grep -Fxq "Identifier=$identifier" || fail "$name ($arch) has the wrong signing identifier"
    printf '%s\n' "$details" | grep -Fxq "TeamIdentifier=$team" || fail "$name ($arch) has the wrong team"
    printf '%s\n' "$details" | grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' || fail "$name ($arch) has no Hardened Runtime flag"
    printf '%s\n' "$details" | grep -Eq '^Timestamp=.+$' || fail "$name ($arch) has no secure timestamp"
    entitlements="$dist/$name-$arch-entitlements.plist"
    codesign -d --arch "$arch" --entitlements - --xml "$binary" > "$entitlements"
    if [ -s "$entitlements" ]; then
      plutil -lint "$entitlements"
      if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" >/dev/null 2>&1; then
        fail "$name ($arch) has get-task-allow"
      fi
    fi
  done
}

codesign --verify --deep --strict --verbose=2 "$app"
verify_binary "$app/Contents/MacOS/awake" "$app_id" awake
verify_binary "$app/Contents/MacOS/awake-helper" "$app_id.helper" awake-helper
verify_binary "$app/Contents/Frameworks/Sparkle.framework/Sparkle" org.sparkle-project.Sparkle sparkle
verify_binary "$sparkle/Versions/B/Autoupdate" org.sparkle-project.Sparkle.Autoupdate sparkle-autoupdate
verify_binary "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater" org.sparkle-project.Sparkle.Updater sparkle-updater
verify_binary "$sparkle/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" org.sparkle-project.DownloaderService sparkle-downloader
verify_binary "$sparkle/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" org.sparkle-project.InstallerLauncher sparkle-installer
for arch in arm64 x86_64; do
  otool -arch "$arch" -l "$app/Contents/MacOS/awake" | grep -Fq 'path @executable_path/../Frameworks (offset ' || fail "awake ($arch) cannot locate embedded frameworks"
done
# Loading the packaged executable catches missing framework paths that a successful build does not.
"$app/Contents/MacOS/awake" status | tee "$dist/runtime-status.txt"
info="$app/Contents/Info.plist"
for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUAllowsAutomaticUpdates SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
  [ "$(plutil -extract "$key" raw -o - "$info")" = "$(plutil -extract "$key" raw -o - "$here/App/Info.plist")" ] || fail "bundled $key differs from its source"
done
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$info")" = "$version" ] || fail "app version differs from MARKETING_VERSION"
[ "$(plutil -extract CFBundleVersion raw -o - "$info")" = "$build" ] || fail "app build differs from CURRENT_PROJECT_VERSION"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$info")" = "$app_id" ] || fail "wrong app bundle identifier"
[ "$(plutil -extract CFBundleExecutable raw -o - "$info")" = awake ] || fail "wrong app executable"
[ "$(plutil -extract CFBundleIconName raw -o - "$info")" = AppIcon ] || fail "missing app icon name"
[ -s "$app/Contents/Resources/AppIcon.icns" ] || fail "missing compiled app icon"
[ -s "$app/Contents/Resources/Assets.car" ] || fail "missing compiled icon assets"
for plist in \
  "LaunchDaemons/$app_id.helper.plist" \
  "LaunchAgents/$app_id.menu.plist" \
  "LaunchAgents/$app_id.reconcile.plist"; do
  plutil -lint "$app/Contents/Library/$plist"
  cmp -s "$here/App/$plist" "$app/Contents/Library/$plist" || fail "bundled $plist differs from its source"
done
echo "verified app version $version ($build), signatures, architectures, icon and launchd plists"

notarize() {
  local artifact="$1" label="$2" result status id submitted=true
  result="$dist/notary-$label.json"
  if ! xcrun notarytool submit "$artifact" "${notary_auth[@]}" --wait --output-format json > "$result"; then
    submitted=false
  fi
  cat "$result"
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null)" || status=""
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null)" || id=""
  if ! "$submitted" || [ "$status" != Accepted ]; then
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" "${notary_auth[@]}" || true
    fi
    fail "$label notarization was not Accepted"
  fi
}

assess() {
  local label="$1" result accepted=true
  shift
  result="$dist/gatekeeper-$label.log"
  if ! spctl -a -vvv "$@" > "$result" 2>&1; then accepted=false; fi
  cat "$result"
  if "$skip_notarize"; then
    if ! "$accepted"; then
      echo "warning: Gatekeeper rejected $label, expected for an unnotarized check build" >&2
    fi
  else
    "$accepted" || fail "Gatekeeper rejected $label"
    grep -Fq 'source=Notarized Developer ID' "$result" || fail "$label is not assessed as notarized Developer ID"
  fi
}

archive="$dist/Awake-$version.zip"
if "$skip_notarize"; then archive="$dist/Awake-$version-unnotarized.zip"; fi
ditto -c -k --keepParent "$app" "$archive"
if ! "$skip_notarize"; then
  notarize "$archive" app
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  # The published update archive must contain the stapled app, not the pre-notarization copy.
  ditto -c -k --keepParent "$app" "$archive"
fi
assess app "$app"

stage="$dist/staging"
mkdir -p "$stage"
ditto "$app" "$stage/Awake.app"
ln -s /Applications "$stage/Applications"
# A check build never carries the release's name, so it can't be uploaded by mistake.
dmg="$dist/Awake-$version.dmg"
if "$skip_notarize"; then dmg="$dist/Awake-$version-unnotarized.dmg"; fi
hdiutil create -volname Awake -fs HFS+ -format UDZO -srcfolder "$stage" "$dmg"
codesign --force --sign "$identity" --identifier "$app_id.dmg" --timestamp "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
if ! "$skip_notarize"; then
  notarize "$dmg" dmg
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
assess dmg -t open --context context:primary-signature "$dmg"

mkdir -p "$mountpoint"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mountpoint"
mounted=true
codesign --verify --deep --strict --verbose=2 "$mountpoint/Awake.app"
assess mounted-app "$mountpoint/Awake.app"
[ "$(readlink "$mountpoint/Applications")" = /Applications ] || fail "DMG Applications link is missing"
hdiutil detach "$mountpoint"
mounted=false
rmdir "$mountpoint"
rm -rf "$stage"

sha="$(shasum -a 256 "$dmg" | awk '{ print $1 }')"
echo "DMG: $dmg"
echo "SHA-256: $sha"
if "$skip_notarize"; then exit 0; fi
cat > "$dist/awake.rb" <<EOF
cask "awake" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/theyluvEnething/awake/releases/download/v#{version}/Awake-#{version}.dmg"
  name "Awake"
  desc "Keep your Mac awake while Claude Code or Codex works"
  homepage "https://github.com/theyluvEnething/awake"

  depends_on macos: ">= :tahoe"

  app "Awake.app"

  zap trash: [
    "~/Library/Application Support/awake",
    "~/Library/Logs/awake.log",
  ]
end
EOF
echo "cask: $dist/awake.rb"

# Publish a single full update, signed by Sparkle's existing Keychain signer.
signature="$("$sparkle_bin/sign_update" --account "$update_account" -p "$archive")"
[[ "$signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] || fail "invalid update signature"
length="$(stat -f '%z' "$archive")"
minimum="$(plutil -extract LSMinimumSystemVersion raw -o - "$info")"
[[ "$minimum" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "invalid minimum system version: $minimum"
published="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"
cat > "$dist/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Awake</title>
    <link>https://github.com/theyluvEnething/awake/releases/latest</link>
    <description>Awake updates</description>
    <language>en</language>
    <item>
      <title>Awake $version</title>
      <pubDate>$published</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/theyluvEnething/awake/releases/download/v$version/Awake-$version.zip" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$dist/appcast.xml"
"$sparkle_bin/sign_update" --account "$update_account" "$dist/appcast.xml"
"$sparkle_bin/sign_update" --account "$update_account" --verify "$dist/appcast.xml"
signature="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$dist/appcast.xml")"
"$sparkle_bin/sign_update" --account "$update_account" --verify "$archive" "$signature"
(
  cd "$dist"
  shasum -a 256 "Awake-$version.dmg" "Awake-$version.zip" appcast.xml awake.rb > SHA256SUMS
)
echo "verified signed update archive and feed: $dist/appcast.xml"
