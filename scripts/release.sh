#!/bin/bash
# 发布脚本：打包 app bundle + zip + SHA-256 + 版本说明骨架
#   ./scripts/release.sh           交互确认
#   ./scripts/release.sh --force   跳过确认
set -e
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/QuotaDock/Version.swift)
if [ -z "$VERSION" ]; then echo "error: 无法从 Version.swift 提取版本号" >&2; exit 1; fi

if [ "$1" != "--force" ]; then
    echo "将发布 QuotaDock v$VERSION：构建 → zip → SHA-256。继续？(y/N)"
    read -r ans
    [[ "$ans" == "y" ]] || exit 0
fi

./build.sh
DIST="dist/QuotaDock-$VERSION"
rm -rf "$DIST"; mkdir -p "$DIST"
ditto -c -k --keepParent QuotaDock.app "$DIST/QuotaDock-$VERSION-macOS.zip"

(cd "$DIST" && shasum -a 256 *.zip > SHA256SUMS)

cat > "$DIST/RELEASE_NOTES.md" <<EOF
# QuotaDock $VERSION

变更见 CHANGELOG.md「$VERSION」一节。

安装：解压后把 QuotaDock.app 拖到 ~/Applications（或任意目录），双击运行；
开机自启用 ./build.sh --install。

校验：shasum -a 256 -c SHA256SUMS
EOF

echo "发布产物："
ls -la "$DIST"
echo "下一步：git tag v$VERSION && git push --tags，并把 $DIST/* 附到 GitHub/Gitee Release。"
