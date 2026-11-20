#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
build_name="${1:-release}"
case "$build_name" in debug|release) ;; *) printf '用法 %s [debug|release]\n' "$0" >&2; exit 2 ;; esac
swift build -c "$build_name"
bin_dir="$(swift build -c "$build_name" --show-bin-path)"
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
codesign --force --sign "$sign_identity" --timestamp=none --identifier com.native-mail.coremail "$stage"
codesign --verify --strict "$stage"
if [[ -e "$app_dir" ]]; then mv "$app_dir" "$bundle_tmp/previous.app"; fi
if ! mv "$stage" "$app_dir"; then
    if [[ -e "$bundle_tmp/previous.app" ]]; then mv "$bundle_tmp/previous.app" "$app_dir"; fi
    exit 1
fi
printf '%s\n' "$app_dir"
