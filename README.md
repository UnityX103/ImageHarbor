# Image Harbor

原生 macOS 界面，支持 Apple Silicon（ARM64）和 Intel（x86_64），macOS 13 及以上。

[下载最新版](https://github.com/UnityX103/ImageHarbor/releases/latest) · [构建状态](https://github.com/UnityX103/ImageHarbor/actions) · [MIT 许可证](LICENSE)

## 首次使用

1. 打开 App → HTTPS 证书设置。
2. 按当前一步操作。公开证书会直接加入当前用户的“登录”钥匙串，不再让用户选择位置，也不会写入“系统根证书”。
3. 在钥匙串访问中选择“登录”，搜索 mitmproxy，双击证书。
4. 展开“信任”，将“安全套接字层（SSL）”改为“始终信任”。
5. **关闭证书详情窗口，在 macOS 提示中输入 Mac 登录密码并确认保存。窗口未关闭或密码确认未完成时，新设置尚未保存，无法检测到信任状态。**
6. 回 App 检查信任，然后开始采集；在 macOS 对话框中允许修改系统网络设置。直接使用现有浏览器和应用。

存在同名证书时，在“有多个同名证书？”中核对 SHA-256 指纹。没有自动更改证书信任，也不会接收用户的系统密码。

## 系统采集

启动成功后，为网络服务设置 127.0.0.1 上的 HTTP/HTTPS 代理。采集期间暂时关闭这些服务的 PAC、自动发现和 SOCKS 开关，并清空例外；原值在写入之前保存在应用数据目录。这样会暂时替换已有系统代理；若网络必须依赖原代理才能访问外网，可能需要额外配置上游代理（本版尚未提供）。

覆盖遵循 macOS 系统代理的 HTTP/HTTPS 请求。**并非任意进程或任意协议的透明抓包**：绕过系统代理、直接 UDP/QUIC、证书固定、自带证书信任库的应用，以及浏览器缓存和 data/blob 资源不保证可采集。需要时在原浏览器中刷新页面或重新建立连接。

停止时先恢复系统代理，再关闭图片代理监听。独立的 ImageHarborProxy 管理进程保存原配置，检测主 App 退出后尝试恢复；恢复失败会保留备份并重试。强行终止所有进程、重启或权限失败后，重新打开 App，使用“恢复原代理设置”。采集期间其他程序对设置的修改尽量按字段保留；不重复覆盖已接管服务。新增加的网络服务会定期纳入管理。

## 导出

按地址、按文件格式、同一文件夹三种模式。每次创建新目录，使用唯一编号防重名，附带 manifest.json 来源清单。搜索不影响全部导出。HTTP 206 分段单独标注，不自动合并。

## 更新

在应用菜单或侧栏点击“检查更新…”。Sparkle 会检查当前架构的更新，校验内置公钥对应的 EdDSA 签名，并在安装前等待导出结束、停止采集、恢复系统代理。恢复失败时不会继续安装。默认自动检查，安装由用户确认。

1.1.1 及更早版本需手动安装一次新版，此后可在 App 内检查更新。ARM 和 Intel 分别下载对应安装包。当前发行包使用 ad-hoc 签名，尚未配置 Apple Developer ID 签名和公证；更新包的 EdDSA 签名不等同于 Apple 公证。

## 构建和测试

需要 Xcode / Command Line Tools、Python 3 和网络连接。依赖版本及 SHA-256 固定在 `release/config.json`。安装后的 App 无需系统 Python 或 Homebrew。

```sh
./build.sh arm64
./package.sh arm64
./build.sh x86_64
./package.sh x86_64
./scripts/test.sh
```

输出位于 `dist/<架构>/`。支持 `BUILD_DIR`、`OUTPUT_DIR`、`VENDOR_ROOT`。测试包括真实本地 HTTP/HTTPS 图片捕获、三种导出、系统代理备份与恢复，以及更新源校验。CI 分别在 ARM 和 Intel 原生 macOS runner 上执行；CI 的管理员集成测试使用隔离 preferences 文件，不修改实时系统代理。

证书导入显式指定登录钥匙串，保留旧钥匙串 API 以匹配“钥匙串访问”；SDK 会产生弃用提示。

## 开发与发布

使用 `codex app /你的路径/ImageHarbor` 将克隆目录添加为 Codex 项目。主分支与 PR 自动构建、测试两个架构。版本标签触发签名和 GitHub Release 发布，详见 [发布说明](docs/RELEASING.md)。

## 数据位置

`~/Library/Application Support/ImageHarbor`

- `images` / `records.jsonl`：图片缓存和记录。
- `certificates`：证书与私钥，请勿分享此目录。
- `proxy-restore.plist`：未恢复的系统代理备份；恢复成功后删除。
- `proxy-status.json`：系统代理管理状态。

参考：[Apple 代理设置](https://support.apple.com/zh-cn/guide/mac-help/mchlp2591/mac) · [Apple 证书信任](https://support.apple.com/zh-cn/guide/keychain-access/kyca11871/mac)
