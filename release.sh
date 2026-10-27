#!/bin/sh
# Builds both apps on this Mac and publishes them as a GitHub release.
#
#   ./release.sh 1.0.2            bump both apps to 1.0.2, build, sign, tag and publish
#   ./release.sh 1.0.2 --dry-run  build into dist/dry-run/ only; nothing is committed or published
#
# Needs: Xcode, Android SDK, gh (logged in), and android/keystore.properties with the release key.
set -e
cd "$(dirname "$0")"

VERSION="$1"
DRY=""; [ "$2" = "--dry-run" ] && DRY=1
die() { echo "release: $*" >&2; exit 1; }

echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "usage: ./release.sh 1.2.3 [--dry-run]"
[ -f android/keystore.properties ] || die "android/keystore.properties is missing, so the APK can't be signed"
if [ -z "$DRY" ]; then
  [ "$(git branch --show-current)" = main ] || die "switch to main first"
  [ -z "$(git status --porcelain)" ] || die "commit or stash your changes first"
  git fetch -q origin
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main isn't in sync with GitHub; pull or push first"
  git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "v$VERSION already exists"
fi

# Version: versionName/short version from the argument, build numbers go up by one
GRADLE=android/app/build.gradle.kts PLIST=mac/Info.plist
CODE=$(($(sed -n 's/.*versionCode = \([0-9]*\).*/\1/p' $GRADLE) + 1))
BUILD=$(($(sed -n 's/.*CFBundleVersion<\/key><string>\([0-9]*\)<.*/\1/p' $PLIST) + 1))
sed -i '' "s/versionCode = [0-9]*/versionCode = $CODE/; s/versionName = \"[^\"]*\"/versionName = \"$VERSION\"/" $GRADLE
sed -i '' "s#\(CFBundleShortVersionString</key><string>\)[^<]*#\1$VERSION#; s#\(CFBundleVersion</key><string>\)[^<]*#\1$BUILD#" $PLIST
sed -i '' "s/Version [0-9.]* is out/Version $VERSION is out/; s/· v[0-9.]*</· v$VERSION</" docs/index.html
echo "→ Hop $VERSION (Android build $CODE, Mac build $BUILD)"

echo "→ Android"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
(cd android && ./gradlew -q assembleRelease)
APK=android/app/build/outputs/apk/release/app-release.apk
APKSIGNER=$(ls -d "$HOME"/Library/Android/sdk/build-tools/* | sort -V | tail -1)/apksigner
"$APKSIGNER" verify --print-certs "$APK" | grep -q "CN=Hop" || die "the APK isn't signed with Hop's release key"

echo "→ Mac"
mac/build.sh >/dev/null

# Dry runs go in their own folder, so they can't be mistaken for the real release files
OUT=dist; [ -n "$DRY" ] && OUT=dist/dry-run
mkdir -p $OUT
cp "$APK" $OUT/Hop-android.apk
rm -f $OUT/Hop-mac.zip
ditto -c -k --keepParent mac/build/Hop.app $OUT/Hop-mac.zip
(cd $OUT && shasum -a 256 Hop-mac.zip Hop-android.apk > SHA256SUMS.txt)
cat $OUT/SHA256SUMS.txt

if [ -n "$DRY" ]; then
  git checkout -- $GRADLE $PLIST docs/index.html
  echo "Dry run: built into $OUT/, version changes undone, nothing published."
  exit 0
fi

echo "→ Publishing v$VERSION"
git commit -qam "Release $VERSION"
git tag "v$VERSION"
git push -q origin main "v$VERSION"
gh release create "v$VERSION" dist/Hop-mac.zip dist/Hop-android.apk dist/SHA256SUMS.txt \
  --title "Hop $VERSION" --generate-notes \
  --notes "**Install:** download \`Hop-mac.zip\` (macOS 14+) and \`Hop-android.apk\` (Android 12+). See the [README](https://github.com/Mr-vero/hop#install)."
echo "Done: https://github.com/Mr-vero/hop/releases/tag/v$VERSION"
