# GitHub Actions 与发布

仓库：https://github.com/tietiezhi-1216/aihub

- Actions：https://github.com/tietiezhi-1216/aihub/actions/workflows/macos.yml
- 下载：https://github.com/tietiezhi-1216/aihub/releases

## 简单流程

推送 main / Pull Request / 手动 Run workflow：跑自动测试、HTTP 回环及独立 CLIProxyAPI 假上游测试，然后构建两个本机架构的应用包。推送 `v主.次.补丁`（例如 v0.1.1）时，同一流程通过后自动发布开发预览 Release；没有自动修改标签或把失败构建发布出去。

使用标准 `macos-15`（arm64）和 `macos-15-intel`（x86_64）runner，明确选择 Xcode 26.3。每份二进制验证实际架构和代码签名；不把 arm64 包标成通用或 Intel 包。GitHub runner 镜像以后移除该 Xcode 时需要显式更新流程，不自动换未知工具链。

发布文件：

- `AIHub-版本-arm64.dmg` / `.zip`：Apple Silicon Mac。
- `AIHub-版本-x86_64.dmg` / `.zip`：Intel Mac。
- `AIHub-版本-架构.sha256`：对应 DMG 与 ZIP 的 SHA-256。

DMG 中只有 AIHub.app 和 Applications 快捷方式；不需要安装脚本、Homebrew、Go 或额外守护服务。CLIProxyAPI 不嵌入应用、不随发布启动；有需要时仍由用户独立配置授权。

Actions 构建产物保留 14 天；Release 附件不受该保留期限影响。发布流程重新运行时仅替换同标签附件；请不要手动移动已发布的版本标签。

## 权限与边界

- 仓库公开，但 CI 只使用合成数据、假密钥与回环服务。不会读取开发机钥匙串、用户输入或现有订阅账号。
- 普通构建仅 `contents: read`；标签发布任务才有 `contents: write`。checkout 不持久化推送凭据，不使用 pull_request_target，GitHub Actions 依赖固定到提交 SHA。
- 无需手动添加 GitHub Token、Apple ID、API Key 或 OAuth Token。发布使用 GitHub 自动生成的本次任务令牌；不输出令牌、不写入下载包。
- 版本来自经过格式验证的标签，build number 来自 Actions run number。在签名前写入 Info.plist。
- ZIP 由 ditto 保留应用资源 / 签名；DMG 创建只打包，不移除 quarantine、不关闭系统安全检查。SHA-256 校验下载完整性，不替代开发者身份或 Apple 公证。

## 尚未正式发布

所有自动发行标记为 **开发预览**：当前 ad-hoc 签名、未 Developer ID / Apple 公证、无 App Sandbox。GitHub 上能够下载不等于 Gatekeeper 放行或真实业务验收。首次启动可能被系统阻止，用户应核对来源后遵循系统提示；不提供关闭安全检查的脚本。

正式发布需由项目所有者提供 Developer ID Application 证书与公证凭据，设计临时 CI keychain、hardened runtime、notarytool 与 stapling，并验收签名更新后的 Keychain / TCC 稳定性。当前不自动生成证书、借用其他应用证书或把开发预览说成已公证。
