# 公共思考参数与本机文字用量

## 已实现的范围

模型详情和听写「思考与输出上限」可明确设置有规格依据的选项。映射仅接受 HTTPS 官方 origin（默认端口）：OpenAI Chat / Responses、Anthropic Messages、Google Gemini；同名模型、协议兼容、SDK 支持或公共目录不会为未知中转、OpenRouter、本机 CLIProxyAPI 或订阅渠道建立映射。Antigravity 原有真实路由不变。

- OpenAI：`reasoning_effort` 或 `reasoning.effort`，只接受本模型已声明的 API effort 值；明确思考时 Chat 使用 `max_completion_tokens`，Responses 始终 `store=false`。
- Anthropic：仅声明的 enabled / disabled / adaptive；enabled 需 `budget_tokens >= 1024` 且 `< max_tokens`。adaptive 可携带已声明的 `output_config.effort`，不能同时预算。不发送工具 / between_tools 配置，不因名字推断 adaptive。
- Gemini：只在声明列表内用 `generationConfig.thinkingConfig.thinkingLevel`，或明确范围内用 `thinkingBudget`，二者互斥。只有目录明确允许自动预算才提供 -1；不根据默认值推断允许关闭，mandatory 禁止 0。`includeThoughts=false`。
- 预算范围未知时不提供任意预算；Anthropic enabled 类型本身的固定协议约束除外。输出上限不会为预算自动增大，应用最大 65536，仍受模型明确限制约束。
- 服务默认不发送 AIHub 指定的思考参数，不等于关闭。规格不证明账户权限、HTTP 接受或实际内部思考效果。
- 选择 / 输出上限按真实渠道模型保存，刷新保留；规格撤回、互斥或超限在凭据解析 / 网络前拒绝，不换模型、档位、协议、账号或后端。用户可明确恢复默认。
- 变更清文字验证而保留 ASR；成功验证记录带思考选择，不能冒充所有档位已通过。

## 用量与费用

`AIClient.transformDetailed` 及两个后端返回 `TextGenerationResult`；旧 `transform` 保留文字返回。解析 OpenAI Chat / Responses、Anthropic、Gemini 的原始 usage；账号 SSE 只取报告快照，不累加重复累计计数。没有统计时显示未知，不按字符串长度猜 token。

归一化约定：

- OpenAI 输入总数包含 cache read，输出总数包含 reasoning；有独立单价时从普通桶扣除。没有独立思考价时总输出只收一次。
- Anthropic `input_tokens` 是未缓存输入，cache read / creation 独立相加用于上下文档位，不能再扣一次。output 已含思考，不编造独立 thought 计数。缓存创建 TTL 缺失或 1h / 工具计费尚未接入时费用未知。
- Gemini candidates + thoughts 得到总输出；thoughts 缺失时只有明确总数等于 prompt + candidates 才确认为零，否则输出费用未知。
- 缓存音频的交叉桶细分未知、缺计数 / 费率 / 分档条件、重复规则、不完整 / 非法用量均不估算。超过 14 天或时效未知价格不作为当前调用报价；订阅永远不套用 API 单价。

「用量」默认关闭持久记录，主动开启后仅保留最近 5000 次**成功文字调用**的时间、连接 UUID / 真实模型 ID、协议 / 后端 / 配置、计数及参考估算 / 价格版本。与设置一起原子保存、0600。没有原文、输出、思考、音频、令牌、账号身份或请求 / 响应正文。关闭后不再追加，旧记录由用户明确清除。保存失败仍保留结果和 ASR 原文。

表格合计只覆盖保留记录中能够估算的部分，并且按币种分开；不是实际总费用或账单。ASR、失败 / 取消、代理内部额外调用、长缓存及额外工具 / 多模态费用未计入，服务已处理的请求无法因取消撤销计费。真实供应商 usage 语义、账户计价与发票仍待人工验收。

## 配置兼容

配置版本为 v3，读取 v1 / v2 时仅内存迁移；正常保存才升级。原 UUID / Keychain / 后端不变，旧配置不默认启用记录或思考。旧程序拒绝 v3，避免忽略新字段后覆盖偏好和记录。

## 验证与来源

自动测试覆盖两个后端的四协议 body、原鉴权、预算 / 互斥 / 未知渠道、429 单次请求、元数据撤回与保存回滚，以及计费去重、未知费用、记录保留和 ASR 原文。真实回环 HTTP 模拟上游校验具体字段；不使用真实 Key，不证明实际供应商接受或效果。没有继续 Antigravity 429 请求。

参数资料（只作 wire 依据，不能分配给所有模型）：

- https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
- https://developers.openai.com/api/reference/resources/responses/methods/create
- https://platform.claude.com/docs/en/build-with-claude/extended-thinking
- https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking
- https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- https://ai.google.dev/gemini-api/docs/thinking
