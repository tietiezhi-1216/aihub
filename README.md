# AIHub

原生 macOS 应用，使用 SwiftUI 系统侧栏、表单和列表。文字协议可使用原生 Swift AI SDK；连接 CLIProxyAPI 时需要独立的本机服务。

## 当前功能

- 侧栏顺序：**模型 → 听写 → 用量 → 权限**。
- **先选择渠道类型**：账号渠道直接登录，API 渠道才填写名称、地址和密钥。
- 完整模型目录：获取服务端所有分页、去重；保留文本、图片、视频、ASR、TTS、音频、向量、重排序及未知类型；记录服务返回的输入／输出模态，支持按类型筛选和手动修正。
- 单面板模型管理：左侧渠道、右侧模型；使用原生滚动列表，不分页，保留搜索和类型筛选。编辑弹窗也使用滚动模型列表。
- Antigravity 同一模型的思考变体合并为一行，在「思考」中选择已适配的低／中／高等档位；LLM 选择器也只列一次，选择与真实调用 ID 同步。
- 高级协议：自动识别、OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、Google Gemini、小米 MiMo；模型详情可为同一 OpenAI 风格连接中的不同模型选择 Chat／Responses。
- 「模型详情」展示多任务、输入／输出、思考规格、调用协议、价格快照与来源；「更新规格与价格」手动获取 models.dev 公共目录，不发送密钥或用户内容，不替代本渠道目录与调用验证。
- 可选择「内置适配 / Swift AI SDK」文字后端，旧配置保持原后端；新增「CLIProxyAPI（本机）」渠道，只使用该服务的本地访问密钥。
- Codex／Antigravity／Grok 浏览器登录、模型目录与文字调用；PKCE、本机回调、令牌刷新和钥匙串保存。
- API Key／登录凭据文件导入；保留 Google Gemini 的自有桌面 OAuth 客户端流程。
- 录音／音频导入 → ASR 识别 → LLM 润色；「仅识别」与「识别并润色」分别操作，ASR／LLM 可选不同渠道，失败或取消不丢失识别原文。也可直接输入／粘贴文字进行整理或提示词转换。
- 系统麦克风权限检查。

## 构建与运行

需要 macOS 14+、Swift 6+。编译可使用 Command Line Tools；测试建议完整 Xcode。

```bash
./scripts/build-app.sh
open dist/AIHub.app
```

本地调试：

```bash
./scripts/build-app.sh debug
```

请从 .app 测试麦克风，避免 `swift run` 导致系统权限身份不同。当前构建为本机架构，默认 ad-hoc 签名、未公证、未启用 App Sandbox。正式发布需要稳定的 Developer ID 签名和公证：

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

脚本只签名，不自动公证。

## 添加模型

1. 打开「模型」→「添加渠道」，**先选择渠道类型**。
2. Codex／Antigravity／Grok：点击登录，在系统浏览器完成授权。登录前只显示名称和登录操作，不显示 API 地址、API Key 或空模型表；授权后自动获取模型，再保存。
3. API 渠道：填写名称、API 地址、API Key，点击「验证连接并获取模型」再保存。
4. 自定义 API 默认自动识别；需要其他协议或无密钥的本地服务时，在「高级设置」中选择。
5. 没有模型列表接口的渠道可手动添加模型 ID。听写只使用支持语音接口的 API 渠道；账号登录渠道用于文字整理／提示词转换。

官方 Anthropic、Gemini 和小米域名可自动识别协议。只有主机地址时，Gemini 自动补 `/v1beta`，其他协议补 `/v1`；已有路径原样保留。Responses 和 Chat Completions 共享模型列表，**不会仅凭 /models 成功猜测生成接口**，可选择 Responses 渠道、在自定义 API 的高级设置中指定 Responses，或在单个模型详情中明确选择文字协议。

模型目录不按已实现的调用接口过滤，目录获取不会发送音频、图片、视频或文字生成内容。未知类型和服务标记不可用的模型也保留在目录中。模型名称及目录元数据只能提示能力，不保证接口和账户权限；「调用已验证」仅表示成功调用过对应接口。

Antigravity 思考选项只来自本渠道实际获取的目录变体，保留每个真实模型 ID、元数据和独立调用验证。目录只有 low／high 时就只显示低／高，不根据 Gemini 官方 API 文档补出 Antigravity 未确认的 medium，也不猜测其他路由或思考参数。目录返回某档位不等于该账户已成功调用，调用验证单独记录。此前未验收的参数中档已撤回；旧实验配置不会静默降为低档继续执行。原有高／低档选择兼容，不为服务仅提供 Thinking 的模型虚构「关闭」档。版本、Lite／Image、预览和未知类型不会仅凭相同显示名合并；明确的 agent 别名仅在对应基础模型已存在时归入相同档位，调用仍使用其真实 ID。

**当前可执行任务**是 ASR 和文本处理；图片／视频／TTS／向量等已支持目录管理，尚未实现相应生成或调用界面。输入／输出模态优先使用服务返回信息，已知官方 API 可手动更新公共目录参考；详情注明来源，不把发现模型描述为已验证调用。

## 数据模型与规格 / 价格

连接与模型目录分别存储，配置 v1 / v2 在正常保存时迁移到 v3，渠道 UUID、钥匙串凭据、手动模型与原后端不变；旧程序不能覆盖 v3。多任务、模态、调用绑定、思考规格和价格独立建模，不凭同名合并跨渠道模型。已接入官方 OpenAI、Anthropic、Gemini 的有限思考参数控制，只提供模型规格声明且已经映射的选项；未知中转与本机代理不套用这些参数，Antigravity 仍使用真实路由选择。

公共目录只补全已知官方渠道的精确 ID，不能把 Google API 的档位套到 Antigravity，也不能给未知中转或本机代理扩大能力。价格使用 Decimal 和明确单位，保留快照版本、分档条件、来源和时间；未知不等于免费，订阅不套用 API 单价。文字响应解析服务返回的用量，按不重叠计费桶估算；缺计数、缓存时长不明或价格过期时不造零费用。「用量」可主动开启本机记录（默认关闭），保存最近 5000 次成功文字调用的计数、配置及价格版本，不保存原文、结果或思考。不是服务商账单，也尚未记录 ASR、失败／取消费用。详情见 [模型架构](docs/model-architecture.md) 和 [思考与用量](docs/reasoning-usage.md)。

## 文字后端与本机代理

Swift AI SDK 固定为 **0.19.0**（版本和修订写入 `Package.resolved`），只链接 OpenAI Chat／Responses、Anthropic、Gemini 的协议模块，不引入 agent runtime、工具执行或自动重试。新建这四类 API 渠道默认选 SDK；旧配置仍使用内置适配，可在编辑渠道时手动切换。自定义 API 默认内置适配，小米保留专用实现；模型目录、ASR 和 Google／账号授权也保留原实现。SDK 无法解析非标准兼容响应时直接报错，不悄悄再发一次内置请求。

SDK 网络请求始终由 AIHub 的受控传输执行：固定本次授权 URL、只复制 SDK 序列化的 body、不读取环境密钥、不跟随重定向、限制响应大小、脱敏错误，只接受完整用户文字。切换文字后端只清除文字模型的旧调用验证，不删除 ASR 验证或原始目录。

「CLIProxyAPI（本机）」连接用户已运行并独立授权的服务，不是把现有 Codex／Antigravity／Grok 凭据当 API Key。只接受 `127.0.0.1`／`::1` 字面回环地址和 `/v1` 基础路径，访问密钥进入 AIHub 钥匙串。远程代理、LAN 地址、其他 OAuth 凭据及管理路径均拒绝。此渠道暂时只接入目录和文字，不声称有 ASR／图片／视频生成能力。现有三个账号渠道仍为原生直连，没有自动迁移令牌。

可选下载 **CLIProxyAPI 8.0.17**（固定发布包 SHA-256，默认仅放入 `.build/tools`，不自动启动或读取凭据）：

```bash
python3 scripts/install-cli-proxy.py
python3 scripts/test-cli-proxy.py
```

第二条命令启动隔离的临时服务，只使用回环模拟上游和假密钥，结束后停止进程；不是账号授权验收。真实使用需要单独配置并启动服务，限制回环、保护管理接口、关闭敏感日志并审查重试／换账号策略。AIHub 自身不重试或自动切后端；外部服务的行为由其配置决定，不能把本地边界当成已审核了服务内部的一切行为。

许可证随应用放在 `Contents/Resources/ThirdPartyNotices.txt`。详细设计与验收范围见 [后端接入说明](docs/backends.md)。

## 协议

| 协议 | 模型列表 | 文字生成 | API Key 鉴权 |
| --- | --- | --- | --- |
| OpenAI Chat Completions | GET /models | POST /chat/completions | Authorization: Bearer |
| OpenAI Responses | GET /models | POST /responses | Authorization: Bearer |
| Anthropic Messages | GET /models（支持分页） | POST /messages | x-api-key + anthropic-version |
| Google Gemini | GET /models（支持分页） | POST /models/{id}:generateContent | x-goog-api-key |
| 小米 MiMo | GET /models | POST /chat/completions | api-key |

API 渠道实现非流式文字请求；账号渠道使用各自的流式后端并收集完整文字，不含工具调用／AI harness 执行器。被截断、拒绝或无文字的响应不当作成功结果。Responses 请求设置 `store=false`。

### 语音

- OpenAI 兼容转写使用 multipart `POST /audio/transcriptions`，期待 JSON `text`。
- 硅基流动官方域名只发送 `file` 和 `model`，不发送不支持的语言／词汇参数。
- 小米 ASR 使用 chat `input_audio`。应用先将音频转换成 16 kHz 单声道 WAV，再发送 Base64；语言限自动／中文／英文，转换后上限 7 MiB。
- Anthropic Messages／Gemini 文字协议不被冒充为语音接口。
- 通用上传上限 24 MiB，录音最长 10 分钟；小米转换后的大小限制可能要求更短的录音。
- 导入 m4a、mp3、mp4、mpeg、mpga、wav、flac、ogg、webm；实际支持格式由供应商决定，格式转换另受 macOS 解码能力限制。
- OpenAI `gpt-4o-transcribe-diarize` 使用自动分段与 JSON 文本结果，不发送其不支持的词汇提示；当前不显示说话人分段。
- 快捷键仅在应用内有效：⌘⇧R 录音／停止，⌘O 导入，⌘↩ 仅识别，⌘⇧↩ 识别并润色。

## 授权与鉴权文件

支持以下 **JSON** 文件，必须由用户主动选择，不扫描其他应用的登录目录：

- API Key：`api_key`、`OPENAI_API_KEY`、`ANTHROPIC_API_KEY`、`GEMINI_API_KEY`、`XAI_API_KEY`，一次只导入一组。
- Codex `auth.json`：API Key 模式用于 API 渠道；完整 `tokens` 登录模式用于 Codex 渠道，要求 access_token、refresh_token 和账户标识。
- Grok：支持明确标注渠道的 OAuth 文件、`xai` 登录对象，以及 `https://auth.x.ai::客户端ID` 对象。
- Antigravity：支持对应公共客户端的 Google `authorized_user` 文件；不能拿其他 Google 客户端的凭据代替。
- Google `authorized_user` 文件：要求 `client_id`、`client_secret`、`refresh_token`；使用官方 Gemini API，可附带 `quota_project_id`。
- 绑定地址的 Bearer 文件：

```json
{
  "api_address": "https://your-api.example/v1",
  "api_protocol": "openAIResponses",
  "access_token": "YOUR_TOKEN"
}
```

文件中的敏感值只进入钥匙串，不进入配置文件；原文件不会被修改或删除。Bearer 文件绑定 API 基础地址，不实现任意厂商令牌刷新。

### Google 官方 OAuth

1. 在 Google Cloud 创建／启用相应 API 项目、配置 OAuth 同意屏幕，创建 **Desktop app** 客户端并下载客户端 JSON。
2. 添加渠道，选择「Google Gemini OAuth（自有客户端）」。
3. 点击登录，选择下载的客户端 JSON，在浏览器完成授权。
4. 自动获取模型后保存。

此 Gemini API 流程使用用户自己的 OAuth 客户端和回环随机端口；令牌仅用于官方 Gemini API。它与 Antigravity 渠道独立，也不使用 Gemini CLI 额度。

### Codex／Antigravity／Grok 登录

三类账号渠道内置对应已公开的安装型 OAuth 客户端参数，无需填写 API 地址或 API Key。使用浏览器授权码＋PKCE＋随机 state，回调仅绑定 IPv4 回环，按注册要求使用固定端口；登录会超时或可取消。access_token、refresh_token、账户标识和项目只进入钥匙串（未保存草稿仅留在内存）。

- **Codex**：ChatGPT 登录，账户专属 `/backend-api/codex/models` 和流式 Responses；不会发送到 OpenAI API Key 计费接口。
- **Grok**：xAI 登录，`cli-chat-proxy.grok.com` 模型目录与流式聊天；不读取网页 Cookie，不处理／绕过验证码。
- **Antigravity**：目录直接调用 `fetchAvailableModels`，不先获取生成项目、不发送音频或生成内容。目录使用固定 daily 端点，网络故障／404／5xx 时可尝试固定 production 端点；400／401／403／429 和地区／账户限制不换端点。实际文字生成才读取本人 `loadCodeAssist` 项目；不借用固定项目、不自动创建项目，未启用的账号需要在官方应用完成启用。

**重要**：这些专用后端不是通用公开 API，账号权限、额度、客户端注册和服务条款会影响可用性。Antigravity 第三方使用尤其可能导致账号受限，登录前会提示风险；不绕过资格校验、验证页面或访问限制。尚未完成真实账户端到端验收，不保证服务方长期允许第三方使用。Gemini CLI 专用登录仍未实现。详见 [协议与授权边界](docs/protocols-auth.md)。

## 数据与安全

- 配置：`~/Library/Application Support/AIHub/settings.json`，包含渠道、协议、鉴权类型、模型、偏好及价格快照；主动启用记录后还包含文字用量计数与参考估算，不包含输入或结果。
- 凭据：macOS 钥匙串，service `app.aihub.provider-credentials`，不启用 iCloud 同步。
- 兼容原配置；原子保存、文件权限 0600，保存失败尝试回滚凭据，损坏配置不自动覆盖。
- 更换渠道类型、API 地址、协议或鉴权方式需重新提供凭据；不自动向新地址发送旧密钥。
- 远程只允许 HTTPS，HTTP 仅用于本机回环；拒绝重定向、不缓存 Cookie，不回显原始错误响应。
- 只有点击「仅识别」或「识别并润色」才上传音频；后者明确执行 ASR → LLM，LLM 只收到识别文字。手动点击文字转换也可发送输入文字，取消不能撤销服务端已处理或计费的请求。
- 录音在清除、重新录音或正常退出时删除；异常退出的过期录音在后续启动清理。导入原文件不删除，转写文字不保存历史。
- 不申请辅助功能、屏幕录制或 Apple Speech 权限，不跨应用自动粘贴。

## 测试

```bash
./scripts/test.sh
./scripts/test-integration.sh
# 可选真实本机代理 + 模拟上游：
python3 scripts/test-cli-proxy.py
```

覆盖协议路由／请求／响应、全模态模型目录与筛选、Antigravity 目录／项目分离及限定故障回退、分阶段且脱敏的错误、模型分页、旧配置兼容、PKCE／OAuth 回调校验、凭据导入／刷新／绑定／回滚、WAV 转换、ASR → LLM 顺序、取消及保留原文。

集成测试仅绑定本机回环，验证实际 HTTP 的五种原有 API 协议、四种 SDK 文字协议、模型分页、语音请求、三个账号后端的分段 SSE、重定向拒绝、响应限额与取消。模拟接口**不识别真实语音，也不访问真实账户或付费供应商**。

真实厂商接口、三个账号登录通道与 Google 自有客户端授权、麦克风权限弹窗及识别质量还需有凭据的环境人工验收，见 [验收清单](docs/acceptance.md)。
