#!/bin/bash
# 发布新版本到 GitHub Release，供应用内「检查更新」下载。
#
# 用法：  Scripts/release.sh <版本号，如 0.4.0> [更新说明文件]
#
# 步骤：更新 Info.plist 版本号（构建号自动加 1）→ 打包签名 → 生成 Coremail-<版本>-macOS.zip
#       → 提交并打 tag v<版本> → 推送 → gh release create。
# 应用只会安装与当前版本同一开发者证书签名的更新包，因此拒绝临时签名的构建。
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:-}"
notes="${2:-}"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    printf '用法: %s <版本号，如 0.4.0> [更新说明文件]\n' "$0" >&2
    exit 2
fi
if [[ -n "$notes" && ! -f "$notes" ]]; then echo "找不到更新说明文件：$notes" >&2; exit 2; fi

plist="Scripts/Info.plist"
current="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")"
newest="$(printf '%s\n%s\n' "$current" "$version" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)"
if [[ "$version" == "$current" || "$newest" != "$version" ]]; then
    echo "新版本 $version 必须高于当前版本 $current" >&2
    exit 1
fi

if [[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]]; then echo "请在 main 分支上发布" >&2; exit 1; fi
if [[ -n "$(git status --porcelain)" ]]; then echo "工作区有未提交的改动，请先提交" >&2; exit 1; fi
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then echo "tag v$version 已存在" >&2; exit 1; fi
gh auth status >/dev/null

echo "运行测试…"
swift test >/dev/null

/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $((build + 1))" "$plist"
restore() { git checkout -- "$plist"; }
trap restore ERR

app="$(Scripts/build-app.sh release | tail -1)"
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ -z "$team" || "$team" == "not set" ]]; then
    echo "构建使用了临时签名，已有安装无法验证这个更新包。请安装开发者证书或设置 NATIVE_MAIL_SIGN_IDENTITY。" >&2
    exit 1
fi

archive="dist/Coremail-$version-macOS.zip"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

git add "$plist"
git commit -q -m "Release v$version"
git tag -a "v$version" -m "Coremail $version"
trap - ERR
git push -q origin main "v$version"

if [[ -n "$notes" ]]; then
    gh release create "v$version" "$archive" --title "Coremail $version" --notes-file "$notes"
else
    gh release create "v$version" "$archive" --title "Coremail $version" --generate-notes
fi
