#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
build_name="${1:-release}"
case "$build_name" in debug|release) ;; *) printf '用法 %s [debug|release]\n' "$0" >&2; exit 2 ;; esac
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
minimum_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Scripts/Info.plist)"
swift build --sdk "$SDKROOT" -c "$build_name" \
    -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_version" -Xlinker "$sdk_version"
bin_dir="$(swift build --sdk "$SDKROOT" -c "$build_name" --show-bin-path)"
app_dir="$PWD/dist/Coremail.app"
bundle_tmp="$(mktemp -d "$PWD/.build/native-mail-bundle.XXXXXX")"
trap 'rm -rf -- "$bundle_tmp"' EXIT
stage="$bundle_tmp/Coremail.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources" "$PWD/dist"
install -m 755 "$bin_dir/NativeMail" "$stage/Contents/MacOS/NativeMail"
install -m 644 "Artwork/Coremail.icns" "$stage/Contents/Resources/Coremail.icns"
install -m 644 "Scripts/Info.plist" "$stage/Contents/Info.plist"
plutil -lint "$stage/Contents/Info.plist"
sign_identity="${NATIVE_MAIL_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null | awk '
        /"(Apple Development|Apple Distribution|Developer ID Application):/ { print $2 }
    ' || true)"
    if [[ -n "$identities" && "$identities" != *$'\n'* ]]; then
        sign_identity="$identities"
    else
        sign_identity="-"
    fi
fi
# WidgetKit extensions are embedded and signed before their containing app.
widget="$stage/Contents/PlugIns/CoremailWidget.appex"
mkdir -p "$widget/Contents/MacOS"
install -m 644 Scripts/Widget-Info.plist "$widget/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" Scripts/Info.plist)"
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$widget/Contents/Info.plist"
done
xcrun swiftc -sdk "$SDKROOT" -target "$(uname -m)-apple-macosx$minimum_version" \
    -parse-as-library -emit-module -emit-object -module-name WidgetShared \
    Sources/WidgetShared/WidgetSnapshot.swift -emit-module-path "$bundle_tmp/WidgetShared.swiftmodule" \
    -o "$bundle_tmp/WidgetShared.o"
# Enter through Foundation’s extension bootstrap, not the generated Swift main.
# Using the normal executable entry point crashes ExtensionFoundation on launch.
xcrun swiftc -sdk "$SDKROOT" -target "$(uname -m)-apple-macosx$minimum_version" \
    -O -application-extension -parse-as-library -I "$bundle_tmp" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    Sources/CoremailWidget/CoremailWidget.swift "$bundle_tmp/WidgetShared.o" \
    -o "$widget/Contents/MacOS/CoremailWidget"
# macOS App Groups use a signing-team prefix; use the same group in both bundles.
team=""
if [[ "$sign_identity" != "-" ]]; then
    codesign --force --sign "$sign_identity" --timestamp=none "$widget"
    team="$(codesign -dv "$widget" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
fi
app_group="${NATIVE_MAIL_APP_GROUP:-${team:-local}.com.native-mail.coremail}"
for plist in "$stage/Contents/Info.plist" "$widget/Contents/Info.plist"; do
    /usr/libexec/PlistBuddy -c "Add :CoremailAppGroup string $app_group" "$plist"
done
cat > "$bundle_tmp/app.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.application-groups</key><array><string>$app_group</string></array></dict></plist>
EOF
cp "$bundle_tmp/app.entitlements" "$bundle_tmp/widget.entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$bundle_tmp/widget.entitlements"
codesign --force --sign "$sign_identity" --timestamp=none \
    --entitlements "$bundle_tmp/widget.entitlements" "$widget"
codesign --force --sign "$sign_identity" --timestamp=none --identifier com.native-mail.coremail \
    --entitlements "$bundle_tmp/app.entitlements" "$stage"
codesign --verify --strict "$stage"
if [[ -e "$app_dir" ]]; then mv "$app_dir" "$bundle_tmp/previous.app"; fi
if ! mv "$stage" "$app_dir"; then
    if [[ -e "$bundle_tmp/previous.app" ]]; then mv "$bundle_tmp/previous.app" "$app_dir"; fi
    exit 1
fi
printf '%s\n' "$app_dir"
