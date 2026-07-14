# macOS GitHub Release 配置

仓库已经包含独立的 `release-macos-signed` GitHub Actions 工作流。它不会修改
Xcode Cloud 的现有流程，会单独构建 arm64 macOS App、执行 Developer ID
签名、提交 Apple 公证、staple 公证票据，并将带有 `-notarized.dmg` 后缀的产物
上传为 Actions Artifact。`v*` Tag 构建还会把产物上传到 GitHub Release。

## 当前状态

以下公证凭据已配置到 `xiachufang/motif` 的 Repository Secrets，并且已经使用
Apple `notarytool` 验证：

- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_PRIVATE_KEY_BASE64`

它们使用专门的 App Store Connect API Key：

- Name：`Motif Notary CI`
- Key ID：`WGG99B6XWC`
- Access：`Developer`

以下 Developer ID 签名凭据也已配置：

- `MACOS_DEVELOPER_ID_P12_BASE64`
- `MACOS_DEVELOPER_ID_P12_PASSWORD`

五个 Secret 已全部就绪。Notary API Key 只能认证公证请求，不能代替
Developer ID 代码签名证书。

## 以后重新签发证书

Apple 只允许开发者团队的 Account Holder 创建 `Developer ID Application`
证书。Admin、App Manager 和普通 Developer 都不能创建。

当前 GitHub Release 专用的签名材料位于仓库之外：

```text
/Users/feichao/Library/Application Support/Motif/github-release-signing/Motif-GitHub-Release.key
/Users/feichao/Library/Application Support/Motif/github-release-signing/Motif-GitHub-Release.pem
/Users/feichao/Library/Application Support/Motif/github-release-signing/Motif-GitHub-Release.p12
```

私钥和 P12 不能上传、共享或提交到 Git。如果以后需要重新签发：

1. 在安全目录中生成新的私钥和 CSR。
2. 使用 Account Holder 登录 [Apple Developer Certificates](https://developer.apple.com/account/resources/certificates/add)。
3. 在 Software 分类中选择 `Developer ID Application`，不要选择
   `Apple Development`、`Apple Distribution` 或 `Developer ID Installer`。
4. 上传新 CSR 并下载 Apple 生成的 `.cer` 文件。
5. 验证证书与新私钥匹配后，再生成 P12 并更新 GitHub Secrets。

## 生成 P12 并配置 GitHub Secrets

下载 `.cer` 后，可以交给 Codex 继续操作；它会验证证书类型、与本地私钥是否
匹配，然后生成带随机密码的 P12，并写入两个 GitHub Secrets。

如果需要手动完成，先将路径替换成实际下载的证书路径：

```bash
SIGNING_DIR="$HOME/Library/Application Support/Motif/github-release-signing"

openssl x509 \
  -inform DER \
  -in "$HOME/Downloads/developerID_application.cer" \
  -out "$SIGNING_DIR/Motif-GitHub-Release.pem"

openssl pkcs12 -export \
  -inkey "$SIGNING_DIR/Motif-GitHub-Release.key" \
  -in "$SIGNING_DIR/Motif-GitHub-Release.pem" \
  -name "Motif GitHub Release" \
  -out "$SIGNING_DIR/Motif-GitHub-Release.p12"
```

然后配置 Secrets：

```bash
openssl base64 -A \
  -in "$SIGNING_DIR/Motif-GitHub-Release.p12" \
  | gh secret set MACOS_DEVELOPER_ID_P12_BASE64 --repo xiachufang/motif

gh secret set MACOS_DEVELOPER_ID_P12_PASSWORD --repo xiachufang/motif
```

第二条命令会交互式读取 P12 导出密码，避免密码进入 shell history。

## 验证工作流

所有五个 Secrets 配置完成后：

1. 推送包含工作流的分支；每次分支 push 都会运行
   `release-macos-signed`，但不会发布 GitHub Release。
2. 也可以在 GitHub Actions 页面手动运行 `release-macos-signed`。
3. 确认 `Sign app with Hardened Runtime`、`Notarize and staple DMG` 和
   `Upload workflow artifact` 全部成功。
4. 下载 Actions Artifact，在另一台 Mac 上直接打开并运行，确认 Gatekeeper
   不显示未识别开发者警告。
5. 推送下一个 `v*` Tag。Tag 构建会把
   `Motif-vX.Y.Z-notarized.dmg` 上传到对应 GitHub Release。

可以在下载后额外检查产物：

```bash
spctl --assess --type open --context context:primary-signature --verbose=2 \
  Motif-vX.Y.Z-notarized.dmg

xcrun stapler validate Motif-vX.Y.Z-notarized.dmg
```

## 与 Xcode Cloud 的关系

Xcode Cloud 仍按原来的脚本运行，并继续上传原有名称的 DMG。GitHub Actions 使用
`-notarized.dmg` 后缀，避免两条流水线对同名 Release Asset 产生覆盖或竞态。
