# 渠道与模型数据层（配置 v3）

## 关系与边界

```
模型厂商 / ModelDeveloper
  └─ 基础目录身份 / ModelDefinition（可为空，命名相似不是身份）
接入服务 / AccessService
  └─ 用户连接 / ProviderConnection
      └─ 渠道目录 / ProviderCatalog
          └─ 渠道模型 / ModelOffering
              ├─ 多任务 + 输入 / 输出模态
              ├─ ReasoningSpec：开关、effort、预算范围
              ├─ InvocationBinding：任务 + 协议 + 来源
              ├─ InvocationVerification：任务 + 协议 + 后端 + 完成时间
              └─ PriceSchedule：计费规则 + 来源 + 内容寻址版本
```

- `Provider` 是界面兼容门面；连接字段与目录分别存储，不重复维护两套状态。`AIModel` 是 `ModelOffering` 的兼容别名，不是全局模型 ID。
- `OfferingIdentity(connectionID, remoteModelID)` 区分不同渠道的相同模型 ID。参考目录身份单独保存；无法确认时不强行合并。
- 连接 UUID、Keychain account、原始模型 ID、选择与原后端保持不变。配置 v1 / v2 仅在内存解码时迁移到 v3，正常保存才写新格式；不自动保存或重新授权。旧程序不能读取 v3，应使用新版，不用旧版覆盖配置。
- 基础模型厂商与渠道运营方不同：Antigravity 中的 Claude 不能被建模为 Google 开发的模型。未知厂商不从显示名称或中转域名推断。

## 目录与执行

模型任务是集合，模态是独立维度。文字 + 图片输入不等于图片生成；文字 → 音频可能是音乐，不仅凭模态判断 TTS；音频输入 + 文字输出不能在明确 ASR 标记存在时被改成 LLM。

目录解析支持已有 Gemini / Antigravity 字段、Anthropic `capabilities.thinking/effort/image_input/pdf_input`、OpenRouter `architecture/reasoning/pricing`、token 限制和有限的 `supported_endpoints`。缺失信息保持未知；名称分类只作为有标记的线索。每个字段保留来源及获取时间。

`InvocationBinding` 不包含任意 URL、鉴权头或请求 JSON。仅允许现有受控适配器的任务与协议：当前执行仍限文字和 ASR；图片、视频、TTS、向量等目录条目不因此获得执行能力。一个 OpenAI 风格连接中可按模型选择 Chat / Responses，目标地址和凭据边界不变。详情中的「默认 / 服务声明」恢复服务返回的绑定；人工绑定优先且目录刷新保留。失败不切协议重试。

思考控制类型独立。Antigravity 仍只选择真实目录路由；公共 API 的 `ReasoningSpec` 保留来源；只有官方 OpenAI / Anthropic / Gemini 的已映射选项可主动设置，未知中转与本机代理仅展示。默认调用不表示关闭思考；元数据撤回后保留选择并拒绝发送，不静默降档。HTTP 接受、完整文字、真实内部推理强度是不同证据。

调用验证按任务、协议、文字后端与文字思考选择记录。思考 / 输出上限变更清文字验证，独立 ASR 不受影响。协议 / 后端切换清对应文字验证，保留独立 ASR 验证；执行描述变化清验证，单纯刷新时间或价格变化不清验证。旧 `verifiedAt` 保留兼容，但不能冒充所有协议和档位都通过。

## 公共规格更新

「更新规格与价格」经用户确认，单次 GET `https://models.dev/api.json`，24 MiB / 50000 条规范化上限；无钥匙串、鉴权、用户模型 ID、音频、原文或生成请求，不自动跟随重定向、重试或后台联网。

- 解析模型规格、模态、限制、`reasoning_options`（toggle / effort / budget_tokens）与成本；忽略 `env`、`npm`、`api`、provider body 等执行配置。
- 缓存为 `~/Library/Application Support/AIHub/model-metadata.json`，原子替换、0600，包含 MIT 版权 / 许可。缓存损坏不破坏渠道设置；失败 / 取消不替换当前设置和原文。
- 只对已知官方服务命名空间 + 完全一致模型 ID 补参考数据。不把基础 API 能力转移到订阅渠道、CLIProxyAPI 或未知中转；不猜测 alias / suffix 对应版本。
- 服务声明和用户任务修正优先；服务明确不支持思考或明确输出非文字，不被公共目录扩大为支持。公共数据不代表账号权限、可用额度或实际调用验证。
- 更新不替代各渠道获取真实列表，不会在当前连接中添加公共目录的所有模型；无匹配的模型仍保留。
- 这不是跨厂商通用接口标准；目前只有 models.dev 更新源，没有引入 LiteLLM 网关，也不把 OpenRouter 数据套到其他服务。

公共目录缓存与渠道设置是两个独立存储。缓存成功但渠道设置保存失败时，渠道 / 输入状态不变，应用报告失败；磁盘公共缓存可能已更新，下一次获取目录可使用有效新缓存。缓存文件不包含密钥或输入历史。

## 价格

`PriceSchedule` 使用 Decimal、货币、计费模式、获取时间、可选生效时间及规则。规则包含计费维度、数量单位和条件，支持 token / 缓存 / 音频 token，也能表达秒数、字符、图片、视频秒数、请求及尺寸条件。

- models.dev 成本按 USD / 百万 token 解析；明确 OpenRouter 的已知 token 价格按 USD / token 解析。未确认货币、单位、override 或缺少分档的项不猜价格。
- Token 计费桶必须不重叠；缓存 / 思考若已包含于原始总数，调用方需要先归一化，不能再累加。
- `BillableUsage.complete` 默认 false；缺少价格、条件、完整用量或匹配多条规则时估算返回 nil，不返回伪造零费用。
- 按量、订阅、本机、未知分别建模；订阅不套用官方 API 单价。价格待确认不等于免费。
- 价格 ID 按币种和规则内容生成；`AppSettings.priceSnapshots` 保留旧版本，新价格不覆盖旧快照。估算结果绑定快照 ID。
- 超过 14 天或时效未知的价格在详情标为参考；数学估算可用于明确选定的历史快照，但不能被当作当前账单。

文字后端返回 `TextGenerationResult`（文字 + `TokenUsage`），原 `transform()` 保留字符串兼容接口。归一化缓存与思考桶，缺细分、计费条件不明或价格过期时保持费用未知。可选本机 `UsageRecord` 默认关闭，开启后仅保留最近 5000 次成功文字调用及对应价格快照，不保存用户输入 / 输出 / 思考 / 音频。ASR、失败 / 取消费用、服务商账单核对、自动周期更新和订阅额度归一化尚未实现。详见 [思考与用量](reasoning-usage.md)。

## 验证

- 自动化覆盖 v1 / v2 / v3、UUID 与凭据边界、同名不同连接、多任务、能力优先级、公共目录无秘密 / 无执行配置、缓存、取消、不重试、价格精度 / 单位 / 档位 / 快照。
- 真实回环 HTTP 验证公共目录及单连接 Chat / Responses，四种 SDK 协议与原账号 / ASR 测试保留。
- 开发阶段在线公共目录探测：8442 个规范化参考条目、6238 个声明思考支持、7996 个可解析价格快照，规范化缓存往返通过。数量是该次目录快照，不是 AIHub 已接入这些模型或真实账号验收。
- 未继续 Antigravity 的 429 生成请求；真实公开 API、账号权益、各思考参数及实际费用仍需独立用户验收。
