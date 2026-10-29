#!/bin/bash
# 一次性：创建 GestureKit 自签代码签名证书，放进登录钥匙串。
#
# 为什么：ad-hoc 签名时 macOS 按二进制哈希(cdhash)认 App，每次编译都会让
# 「辅助功能」授权失效。用固定证书签名后，身份变成「bundle id + 这张证书」，
# 重新编译也不变，授权一次就够。
#
# 会做的事（都只影响当前用户）：
#   1. 生成 10 年有效的自签证书 "GestureKit Self-Signed"（仅用于代码签名）
#   2. 导入登录钥匙串，并允许 /usr/bin/codesign 使用其私钥
#   3. 把它设为「代码签名」用途的受信任证书（会弹出密码确认）
# 撤销：钥匙串访问 → 登录 → 我的证书 → 删除 "GestureKit Self-Signed"。
#
# 请在 Mac 本机终端运行（第 3 步和首次 codesign 需要图形界面确认）。
set -euo pipefail
trap 'echo "出错：第 $LINENO 行的命令失败（退出码 $?），钥匙串可能未改动或只完成了一部分。" >&2' ERR

NAME="GestureKit Self-Signed"
# 先取完整输出再匹配：直接 `| grep -q` 在 pipefail 下可能因 SIGPIPE 误判为「没有」
has_identity() { local ids; ids=$(security find-identity -v -p codesigning 2>/dev/null || true); [[ $ids == *"\"$NAME\""* ]]; }
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl        # 系统 LibreSSL；Homebrew 的 OpenSSL 3 导出的 .p12 security 读不了

if has_identity; then
  echo "证书 \"$NAME\" 已存在且有效，无需重复创建。"
  exit 0
fi
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "钥匙串里已有 \"$NAME\"，但还不是有效的代码签名身份（多半是没设信任）。"
  echo "请在「钥匙串访问」里删除它后重跑本脚本，或手动把它的「代码签名」设为「始终信任」。"
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$("$OPENSSL" rand -hex 16)   # 只用于临时 .p12，导入后即删除（不用管道：pipefail 下会因 SIGPIPE 静默退出）

cat >"$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "==> 生成证书"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"

echo "==> 导入登录钥匙串（允许 codesign 使用私钥）"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo "==> 设为代码签名受信任（会弹窗要求输入登录密码）"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if has_identity; then
  echo "完成：\"$NAME\" 已可用于签名。"
  echo "接下来运行 ./build.sh --install，再去「辅助功能」最后授权一次；以后重新编译不会再掉权限。"
  echo "首次签名时如弹出「codesign 想要使用钥匙串中的密钥」，请点「始终允许」。"
else
  echo "证书已导入，但系统还不认它是有效签名身份。请在「钥匙串访问」里打开它，"
  echo "把「信任 → 代码签名」设为「始终信任」，然后再运行 ./build.sh。"
  exit 1
fi
