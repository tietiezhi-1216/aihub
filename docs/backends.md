# 后端接入：第一阶段

## 已实现的边界

```
SwiftUI / AppState
  └─ AIClient：验证渠道、模型、凭据和单次请求地址
      ├─ 全量目录、ASR、登录、刷新：原实现
      ├─ 文字 / 内置适配：原实现
      └─ 文字 / Swift AI SDK：AIHubSDK
          └─ 固定授权 URL + AIHub SecureHTTPTransport
              ├─ 公开 API
              └─ 可选独立本机 CLIProxyAPI 服务
```

- `AIHubCore.TextGenerationBackend` 是可注入的文字执行接口；SDK 类型不会泄漏到配置、目录、录音和钥匙串代码。
- `Provider.textBackend` 保存为 `builtIn` 或 `swiftAI`。缺少字段的旧配置默认 `builtIn`，不会因升级自动迁移。新建 OpenAI Chat／Responses、Anthropic、Gemini、CLIProxyAPI 渠道默认 `swiftAI`；小米和自定义 API 默认内置适配。
- `Sources/AIHubSDK/SwiftAITextBackend.swift` 只使用四类供应商的协议模块。没有引入 SwiftAISDK 高层 agent／工具／自动重试执行器，没有模型静态名单过滤。
- SDK 只负责序列化和解析，实际请求从 AIHub 已授权的 `URLRequest` 构造，只复制 body。没有环境密钥读取、SDK 默认共享 Session、自动重定向或其他域名访问。
- SDK 请求响应限制 4 MiB、请求超时上限 120 秒、默认输出上限 4096 tokens；明确设置时受模型声明与应用 65536 上限约束；非正常结束和无用户文字都报错。只收集 text，不把 reasoning／工具输出当润色结果；Responses 设置 `store=false`。
- 错误只展示 AIHub 脱敏错误，不输出 SDK 的原始描述、请求体或响应体。失败或取消不会换后端再发一次；用户可在编辑渠道时明确选择内置适配。
- 切换后端清除文字模型的原调用验证，但保留 ASR 验证、目录、手动分类与凭据。ASR 成功先提交的原文不会被后续 SDK 失败或取消撤销。

## 可选 CLIProxyAPI 本机渠道

新增的是独立的本机 API 渠道，不是迁移已有账号，也不是让订阅令牌经过任意中转。

1. 用户独立配置／授权并运行自己的 CLIProxyAPI 服务。
2. 在 AIHub 添加「CLIProxyAPI（本机）」，填写字面回环地址（如 `http://127.0.0.1:8317/v1`）以及服务的**本地访问密钥**。
3. 获取该服务返回的目录，选择其实际模型 ID，再明确提交文字。

只接受 `127.0.0.1`／`::1`、`/v1`；拒绝 localhost DNS 别名、远程／LAN 地址、管理路径、URL 凭据或其他 OAuth 凭据。密钥保存到 AIHub 自身钥匙串。当前仅支持目录和文字，不能把代理目录中的 ASR／图片／视频等模型等同于已实现执行接口。

AIHub 不自动启动服务，不自动复制现有账号令牌，不扫描 CLIProxyAPI 或其他应用的凭据文件。真实 Codex／Antigravity／Grok 账号渠道仍由原生固定端点适配器处理。外部服务内部的凭据持久化、日志、重试、模型替换、账号／端点选择需要单独审查；客户端没有重试，不代表代理内部也不重试。

## 可复现验证

依赖锁定：

- Swift AI SDK 0.19.0，修订 `9f6c21b979c4b394989411921fb14ab29467f4a6`，`Package.swift` + `Package.resolved`。
- CLIProxyAPI 8.0.17，官方发布包在 `scripts/install-cli-proxy.py` 中固定 macOS 两种架构的 SHA-256，不使用不固定的 latest 下载地址。

```bash
./scripts/test.sh
./scripts/test-integration.sh
python3 scripts/install-cli-proxy.py
python3 scripts/test-cli-proxy.py
./scripts/build-app.sh
```

测试分三层：

- SDK 模拟传输：四种协议、真实 ID、鉴权、环境密钥隔离、错误脱敏、完整结果、取消、不重试；应用级 ASR → LLM 流程覆盖两种后端。
- 真实 URLSession 回环：四种 SDK 文字协议加原有五种协议／账号 SSE／multipart 流程。
- 真正的 CLIProxyAPI 二进制：隔离临时 HOME／auth 目录、关闭管理界面／插件／发现／请求日志，仅配置一个回环模拟上游；成功及模拟 429 各只到达上游一次，错误本地密钥被拒绝。结束后精确停止该进程。

这些验证没有真实账号、没有真实 ASR、没有付费上游。没有继续调用已返回 429 的 Antigravity 账号。

## 数据层补充

配置 v3（兼容 v1 / v2）将 `ProviderConnection`、`ProviderCatalog`、`ModelOffering`、任务 / 模态、`InvocationBinding`、`ReasoningSpec` 与 `PriceSchedule` 分层。SDK 仍仅负责本次明确调用的协议序列化 / 解析，不接管 models.dev、鉴权、目录身份、价格或账号流程；详情见 [模型架构](model-architecture.md)。

## 思考参数与文字用量

`generateDetailed` 返回核心 `TokenUsage`，旧字符串接口保留。经 AIClient 校验后，在已授权请求的序列化 body 上写入有限思考字段，不改 URL / 鉴权、不发送自由 JSON 或依赖 SDK 静态模型名单推断档位。官方 OpenAI / Anthropic / Gemini 的映射覆盖两种文字后端；未知兼容服务与订阅不扩大支持。SDK 传输只保留计数，不留响应正文作为费用历史。可选本机记录默认关闭，详见 [思考与用量](reasoning-usage.md)。

## 尚未完成

- 各 SDK 文字协议的真实厂商账户验收，尤其非标准兼容接口。
- CLIProxyAPI 的应用内进程管理、账号授权桥接与 Keychain 集成；当前连接独立已运行服务，不用表单假装实现账号迁移。
- Go SDK 嵌入桥接、取消传播、版本升级、安全日志和发布签名评估。
- Antigravity tiered 的订阅接口参数映射和真实档位效果。官方界面低／中／高与社区静态模型表不是本账户参数已成功执行的证明。

以上边界验收前，不默认替换现有订阅账号适配器。
