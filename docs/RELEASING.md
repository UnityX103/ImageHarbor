# 发布

1. 修改 `release/config.json` 的 version 和严格递增的 build，更新 RELEASE_NOTES.md。
2. 提交至 main，等待两个原生架构的 CI 全部通过。
3. 创建匹配版本的标签，如 `git tag v1.2.0 && git push origin v1.2.0`。
4. Actions 重新构建测试、打包，使用仓库 Secret `SPARKLE_PRIVATE_KEY` 签署 ZIP，并以仓库内公钥独立验证。全部附件上传至草稿后才公开 Release。已公开版本禁止覆盖，请发布新版本。

更新 feed 按架构分开，位于 latest Release 的 appcast-arm64.xml 和 appcast-x86_64.xml。ZIP 与 DMG 均提供 SHA256SUMS.txt。不要修改已发布 ZIP，否则签名将失效。

维护者的更新私钥保存在 macOS 钥匙串账号 `UnityX103.ImageHarbor`，CI 使用 GitHub 加密 Secret；源码仅包含公钥。妥善备份私钥，切勿将私钥、用户证书、抓取内容或代理备份提交到仓库。更换签名密钥需要按 Sparkle 官方密钥迁移流程处理。

当前没有 Apple Developer ID 证书，应用使用 ad-hoc 签名。未来签名和公证需另外配置 Apple 开发者凭据；现有 EdDSA 密钥只用于验证更新包。
