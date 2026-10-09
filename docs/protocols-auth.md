# 协议与授权边界

## 添加流程

先选择渠道类型。Codex、Antigravity、Grok 显示名称和登录按钮；授权后才展开模型列表，并自动获取目录。API 渠道显示名称、API 地址、API Key。旧渠道配置继续兼容，类型从原协议／鉴权字段推导。

## 分层

- **渠道类型**：决定登录流程、固定订阅后端，或可编辑的 API 地址。
- **协议**：Chat Completions、Responses、Messages、Gemini、MiMo；账号后端有独立适配器。
- **鉴权**：API Key、绑定地址的 Bearer、Google 自有客户端 OAuth、绑定类型和固定地址的账号 OAuth。
- **模型目录**：ID、显示名称、类型、输入／输出模态、服务提供的生成方法、可用性提示、来源、实际调用验证记录；不按已实现的调用任务裁剪目录。

登录凭据不是 API Key，不能转发到中转地址。OAuth 刷新只调用固定服务商令牌端点；文件中的任意 token_endpoint 不会被使用。

## 账号通道

| 渠道 | 登录 | 模型目录 | 文字请求 |
| --- | --- | --- | --- |
| Codex | ChatGPT 浏览器 OAuth＋PKCE | `/backend-api/codex/models?client_version=...` | `/backend-api/codex/responses`，SSE、store=false、账户标识头 |
| Grok | xAI 浏览器 OAuth＋PKCE | `cli-chat-proxy.grok.com/v1/models` | 同域 `/chat/completions`，SSE、CLI 鉴权和模型路由头 |
| Antigravity | Google 浏览器 OAuth＋PKCE | 直接 `fetchAvailableModels`，不依赖生成项目 | `cloudcode-pa.googleapis.com/v1internal:streamGenerateContent`，项目包装与 SSE |

使用公开安装型客户端参数，callback 分别为 localhost:1455/auth/callback、127.0.0.1:56121/callback、localhost:51121/oauth-callback。监听只绑定 127.0.0.1，严格校验注册 Host、路径、state、重复参数；五分钟超时，可取消。授权 URL 不包含 client_secret；授权码不存配置，不需要粘贴到 API Key。

JWT 解码仅提取账户路由／显示提示，不把未经验证的文件内容当作可信身份凭证。浏览器交换通过固定 HTTPS 服务；xAI OIDC 的 id_token 校验本次 nonce；其他流程在返回该声明时也校验，授权码始终受 state／PKCE 绑定。后台再验证访问令牌和账户权限。

令牌、refresh_token、email、账户 ID、Google 项目保存在钥匙串，不存 settings.json。刷新仅在已保存凭据仍与请求快照相同时更新钥匙串；未保存或被替换的凭据不覆盖旧数据。取消不能撤销服务端已经签发的授权或已经处理的请求。

流式响应只保留用户可见文字，不返回 thinking；错误、被截断或缺少完成标记的流不会作为成功结果保存。模型目录成功不等于模型已调用验证。三个账号渠道均不提供听写接口。

### 目录与调用分开

模型目录保留图片、视频、文本、ASR、TTS、音频、向量、重排序和未知类型，包括服务标记隐藏或不可用的条目。目录分类不等于接口已适配；当前可执行任务仍是 ASR 和文本处理，未知能力可由用户修正。ASR → LLM 明确为两个请求：ASR 接收音频，LLM 只接收识别文字；原文和润色结果分开保留。

Antigravity 思考变体以显示投影聚合，原始目录和每个变体的验证记录不删除。只合并已识别的基础 ID 后缀；服务标注的档位优先于旧路由后缀。明确 agent 别名在对应版本化模型已存在时合并，其他同名或不同版本模型不猜测合并。思考偏好保存为基础模型 → 实际变体 ID，原有 `chatSelection.modelID` 继续保存真实 ID，兼容旧选择；不向服务发送显示用基础 ID。思考选项只从本渠道真实返回的目录变体生成，不凭其他渠道文档虚构档位。Gemini 官方 API 支持 medium 不能证明 Antigravity 订阅接口支持相同参数；此前未真实验收的 medium 参数配置已撤回。旧实验配置读取时清除该实验偏好及关联文字模型选择，避免静默降为 low 执行；原始模型目录和正常高／低偏好保留。

Antigravity 目录请求为 `POST :fetchAvailableModels {}`，移除旧 `Client-Metadata` 头及与目录无关的 `loadCodeAssist`。仅使用固定的 `daily-cloudcode-pa.googleapis.com`／`cloudcode-pa.googleapis.com` HTTPS 端点，目录优先 daily，网络故障／404／5xx 才尝试 production，不使用 sandbox，不因参数错误、账号权限、地区限制或额度不足换端点。钥匙串凭据仍绑定原渠道的 canonical 地址。生成才读取本人项目，初始化 metadata 只发送 `ideType=ANTIGRAVITY`，不发送未确认的 platform／pluginType 枚举。

网络错误区分目录、账户项目、语音识别和文字生成阶段，不再给目录失败显示“音频参数”提示；只输出 HTTP 状态、预先定义的错误原因及允许列表内的字段名，不回显上游自由文本、参数值或验证 URL。

### 特别限制

- 专用后端、OAuth 客户端注册及条款可能变更。自动化测试不是服务商授权承诺。
- **Antigravity** 使用非公开后端，第三方使用有账号限制风险；界面登录前要求确认。生成时账号未分配项目则提示先在官方应用启用，不借用默认项目、不自动开户或改变订阅。
- **Grok** 不读取网页 Cookie、不使用验证码／反机器人绕过；访问限制和额度不足会正常报错。
- 不在失败后自动改走按量计费 API，也不以重试／换账号规避限制。
- **Gemini CLI** 专用账号通道仍未实现。Gemini API 的自有客户端 OAuth 是另一个类型，权限和额度不同。

## API 与语音

五种 API 文字协议及 Anthropic／Gemini 分页继续保留。OpenAI 兼容 multipart ASR、小米 chat input_audio ASR 独立于账号登录后端。Google Gemini 自有桌面客户端流程支持随机回环端口、PKCE、authorized_user 文件和令牌刷新，仅用于官方 Gemini API。

用户主动选择 JSON 文件，不扫描 `~/.codex`、`~/.grok`、`~/.gemini` 或 Antigravity 数据目录。API Key 模式与完整账号登录模式根据所选渠道分别处理，错误类型拒绝导入；原文件不修改。

## 参考与实现依据

- OpenAI API：https://platform.openai.com/docs/api-reference/responses
- Codex 公开登录实现：https://github.com/openai/codex/tree/main/codex-rs/login
- Codex 模型目录：https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/endpoint/models.rs
- 公开 Codex／xAI OAuth 实现：https://github.com/earendil-works/pi/tree/main/packages/ai/src/auth/oauth
- xAI OIDC 元数据：https://auth.x.ai/.well-known/openid-configuration
- Grok 专用后端与模型实现：https://github.com/stnly/pi-grok
- Antigravity 社区实现与已公开客户端参数：https://github.com/NoeFabris/opencode-antigravity-auth
- Antigravity 目录／项目请求参考：https://github.com/router-for-me/CLIProxyAPI/tree/main/cmd/fetch_antigravity_models 、https://github.com/lbjlaq/Antigravity-Manager/blob/main/src-tauri/src/modules/quota.rs
- OpenAI 转写与分段：https://platform.openai.com/docs/guides/speech-to-text
- Gemini 官方思考档位：https://ai.google.dev/gemini-api/docs/thinking （Gemini 3.1 Pro 支持低／中／高；不能当作 Antigravity 账号后端验收证明）
- Antigravity 社区参数格式参考：https://github.com/NoeFabris/opencode-antigravity-auth/blob/main/src/plugin/request.ts （不是本账户实际接受任意思考档位的证明）
- Google Native OAuth：https://developers.google.com/identity/protocols/oauth2/native-app
- Gemini API OAuth：https://ai.google.dev/gemini-api/docs/oauth
- Anthropic：https://docs.anthropic.com/en/api/messages
- 小米 MiMo：https://platform.xiaomimimo.com/docs

## 验证与发布

已覆盖模拟授权交换、刷新、类型／地址绑定、真实回环回调、超时与取消、模型目录解析及三个账号后端请求／SSE 解析；另通过回环 HTTP 服务验证分段 SSE（测试传输层映射，生产地址仍固定）。**真实账号登录、权限、额度及文本调用仍待人工端到端验收**。

发布前需要稳定 Developer ID 签名／公证、TCC 与钥匙串复测、网络和麦克风验收，以及对第三方登录条款和客户端注册可用性的再次核查。
