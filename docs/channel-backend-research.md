# 渠道后端与 tiered 调查

本次结论分为官方文档、真实账户请求、社区实现三种证据，不互相替代。

## Antigravity 的 tiered

- `tiered` 字面含义是“分档”。检查官方模型页面实际按钮后，确认 Gemini 3.6／3.7／3.8 Flash 的思考选择是 Low、Medium、High；Gemini 3.1 Pro 的该渠道选择是 Low／High。页面中的 Fast 是 `model-badge` 速度标签，不是思考选项；不能根据纯文字抓取把它误列为第四档。
- 这支持“Flash 可以选择不同思考强度”的判断，但所查官方页面没有定义 `-tiered` 后缀，也没有公开这些选项的订阅接口参数映射。不能据此推导 `minimal`、`off`、`xhigh` 或 `thinkingBudget=0` 也被此账号后端接受。
- 实时 `:fetchAvailableModels {}` 返回 27 项，包含 `gemini-3.6-flash-tiered`。此条目的 `supportsThinking=true`、`minThinkingBudget=32`；没有返回 `supportedThinkingLevels`。单凭支持思考和预算下限不能推导“支持全部思考等级”。
- 使用 AIHub 自身已保存的 Antigravity 凭据和本人项目，向固定 production 生成端点发送一条简短默认档请求。结果 HTTP 429（限流或额度不足），已停止。未执行后续 low／medium／high／minimal 生成测试，未切换账号、端点或计费 API。
- 请求成功本身也不能证明内部思考强度被采用；如以后完成测试，应分别记录“请求被接受”“返回完整文字”“服务返回的用量或其他可核对元数据”，不依赖模型口头自报。
- 一次额外的只读目录诊断在输出结果前超时；该诊断设置为 catalog-only，不会继续发送生成请求。没有把这个未完成诊断当作验证结论。
- 未改变应用的思考菜单或当前模型选择。测试辅助文件与脱敏结果位于 `.build/research/tiered/`，凭据、本人项目 ID、原始上游响应和思考内容未写入这些结果文件。

官方来源：

- https://antigravity.google/docs/models
- https://antigravity.google/docs/models.md

## 多供应商 SDK／后端候选

### Swift AI SDK：最贴合原生 Swift 的 API 调用层

- 项目：https://github.com/teunlao/swift-ai-sdk
- 原生 SwiftPM，当前 Package.swift 最低 Swift 6、macOS 13，Apache 2.0。
- README 宣称 38 个供应商模块，统一文本生成、流式、结构化输出、工具调用；源码也有转写、语音合成等能力。视频生成标为实验性，不能解释为所有厂商都实现全部模态。
- 适合统一 OpenAI／Anthropic／Gemini／xAI／Groq 等公开 API 调用，不是 Vercel 官方 Swift SDK。
- 本次未找到内置 Codex／Antigravity／Grok 订阅账号授权后端的证据，不能用普通供应商模块替代这些渠道的登录、固定端点与令牌刷新。

### CLIProxyAPI：最接近跨账号渠道的可复用后端

- 项目：https://github.com/router-for-me/CLIProxyAPI
- 支持 Codex、Antigravity、Gemini CLI、Claude Code、Grok Build 等账号渠道，并暴露兼容 OpenAI／Gemini／Claude 的接口；也接收部分公开 API 上游。
- 不只是独立服务器：提供 Go `sdk/cliproxy`，可嵌入认证、刷新、协议转换和路由。Swift 应用更实际的接法是受管的本机辅助进程，或额外设计受控桥接，而不是直接导入 Go 包。
- MIT。当前主分支模块为 `/v8`，部分 SDK 文档示例仍是 `/v6`，集成必须锁定具体版本、检查对应源码并做最小验收。
- 文档：https://github.com/router-for-me/CLIProxyAPI/blob/main/docs/sdk-usage.md
- 默认文件凭据、请求日志、账户轮换、自动重试、endpoint fallback 等行为不等于符合 AIHub 的现有安全边界。若采用，需限定回环、保护本地管理接口、独立凭据存储、禁用敏感请求日志，不将订阅令牌交给远程中转，不遇到额度／账户限制就自动换渠道。
- 模型能力包含静态维护数据。本次查看的社区模型表甚至把 Gemini 3.1 Pro 列为低／中／高，与 Antigravity 官方界面仅低／高存在差异；这不是本账户中档可用的证明。社区模型表的档位不能取代用户账号实际目录或真实调用验收，也不能保证 ASR／图片／视频等接口全覆盖。

### LiteLLM：更适合服务端网关

- 项目：https://github.com/BerriAI/litellm
- 多供应商统一 API、路由和监控的成熟 Python 网关；对小型原生 macOS 应用意味着额外服务与运行时。
- 不能简单说“只支持 API Key”：已有 ChatGPT 订阅 OAuth device flow 的官方文档，但这不代表覆盖所有订阅账号渠道或可直接替代 Antigravity。
- https://docs.litellm.ai/docs/providers/chatgpt

### Vercel AI SDK：TypeScript 生态参考

- 项目：https://github.com/vercel/ai
- https://ai-sdk.dev/docs/foundations/providers-and-models
- 统一 API 设计和供应商生态较完整，但不是原生 Swift 包；不能直接作为 AIHub 的 Swift 依赖。

## 建议

不存在可靠承诺“所有厂商、所有登录渠道、所有模态全部支持”的单一 SDK。

对 AIHub，优先对 Swift AI SDK 做公开 API 的小规模可替换验证，对 CLIProxyAPI 做账号渠道的本机后端验证；保留 SwiftUI、Keychain、目录管理、用户输入与 ASR → LLM 的阶段提交逻辑。先验收登录、刷新、目录、取消、实际模型 ID、错误脱敏和真实思考参数，再决定是否替换现有适配器。调查之后已开始第一阶段接入：Swift AI SDK 0.19.0 的四个文字协议模块已集成，旧渠道不自动切换；新增可连接独立已运行服务的本机 CLIProxyAPI 渠道。CLIProxyAPI 8.0.17 已按固定 SHA-256 下载并通过真实代理＋模拟上游测试，但没有导入真实订阅令牌或迁移现有账号登录。详见 [后端接入说明](backends.md)。
