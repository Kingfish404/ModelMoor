# ModelMoor 产品边界

ModelMoor 面向单用户，将远端自托管 API、商业 HTTP(S) API 和受支持的订阅模型接入本机，并通过 SSH 将端点带到需要它的机器。核心体验是原生 macOS 应用、CLI/TUI 和可选的 Unified API。

## 三条边界

| 领域 | 约定 |
| --- | --- |
| 监听 | Unified API 只绑定 `127.0.0.1`；SSH 监听仅允许 loopback，不提供公网/LAN 服务或 GatewayPorts |
| 身份 | 本地 key 用于访问控制；不提供多租户、组织角色、充值、账单或按用户计费 |
| 路由与协议 | 公开模型名精确映射上游，不做自动 fallback、负载均衡、推理重试或通用协议转换 |

Codex Responses 和通过官方 CLI 提供的 Claude、Kimi Code、Grok Build 文本聊天是明确支持的订阅路径，不代表支持任意 Anthropic/Gemini 客户端协议。凭据保存在独立的权限受限明文文件中，不使用系统 Keychain。CLIProxyAPI 已退出运行路径。

预算仅按上游 usage 和用户配置价格提供本机估算与告警，不阻断请求，不代表供应商余额、账单或消费上限。ModelMoor 不收集推理正文或 telemetry，不要求 ModelMoor 云账号。

## 与服务端网关的关系

ModelMoor 管理用户自己的端点和 SSH 连接。多用户分发、账务或通用协议适配由独立上游服务处理；这类服务可以作为普通 endpoint 接入。无需维护竞争项目的规模、星数或重叠比例。

## 文档约定

对外统一称 **Unified API**；内部 `ModelMoorGateway`、配置 `gateway` 和 CLI `gateway` 命令保留原名。README 负责入门，[使用指南](usage.md)负责操作与限制，[开发指南](development.md)负责构建和验证。发布历史使用 GitHub Releases，不在这些页面重复维护功能完成清单或测试计数。

涉及监听、身份或路由边界的设计变化，应同步修改本文和相关使用说明。