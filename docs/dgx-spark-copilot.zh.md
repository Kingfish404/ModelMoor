# 接入指南：DGX Spark（Qwen3.8-27B SGLang）-> VS Code Copilot

> 语言 / Language：[中文（本文）](dgx-spark-copilot.zh.md) / [English](dgx-spark-copilot.en.md)

把 NVIDIA DGX Spark 上用 [SGLang](https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark) 服务的 Qwen3.8-27B 模型，通过 ModelMoor 的 SSH transport 接入统一的本地 OpenAI-compatible API。相同 API 也可以同时暴露 DeepSeek 等商业 endpoint 的模型。

```text
DGX Spark (SGLang :8888)
        |  SSH（系统 OpenSSH，ModelMoor 管理）
        v
macOS 本地端口（如 18888）
        |                         DeepSeek / 其他 HTTPS API + Keychain key
        +-----------------------------+
                                      v
ModelMoor Local Gateway（http://127.0.0.1:17777/v1）
        |  一个 URL、一个本地 bearer token、多个稳定模型别名
        v
VS Code Copilot（chatLanguageModels.json 自定义端点）
```

## 1. 在 DGX Spark 上启动 SGLang 服务

参考仓库：<https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark>

前置要求：

- NVIDIA DGX Spark / GB10（aarch64，128 GB 统一内存）
- Docker + NVIDIA Container Toolkit（`docker run --gpus all` 可用）
- `docker`、`curl`；`~/.bashrc` 中定义 `HF_TOKEN`（提高 Hugging Face 拉取限速）

快速启动：

```bash
git clone https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark
cd Qwen3.8-27B-SGLang-DGX-Spark
cp .env.sample .env          # 首次：生成 .env（默认 262K 上下文、10 并发）

./start-dspark.sh           # DSpark 引擎：代码/agent 场景更快（默认推荐）
# ./start.sh                # 或 MTP 引擎：长文写作更快

curl http://127.0.0.1:8888/v1/models   # 服务就绪后返回模型列表
```

要点：

- 服务监听 `0.0.0.0:8888`（host 网络模式），OpenAI 兼容 base URL 为 `http://<DGX-IP>:8888/v1`。
- 模型名（served model name）为 `qwen3.8-27b-sglang`。
- 首次启动会下载约 22 GB 权重到 `./.cache/huggingface`；DSpark 引擎另需约 2.7 GB draft 模型。
- 默认开启 thinking 模式（`reasoning_content`）与 tool calling（`qwen3_coder` parser），无需额外参数。
- 原生上下文 262,144 tokens；可用 `YARN=1` + `CONTEXT_LENGTH` 扩展到 1M（仅 MTP 引擎，DSpark 不支持 YaRN）。
- 停止服务：`./stop.sh`。

## 2. 配置 SSH 主机

ModelMoor 从 `~/.ssh/config`（及其递归 `Include` 文件）发现目标主机。确保其中有一条指向 DGX Spark 的 Host 条目，且为免密（公钥）登录——ModelMoor 使用 `BatchMode=yes`，后台连接不会弹出密码提示：

```ssh-config
Host dgx-spark
    HostName 192.168.x.x
    User <你的用户名>
    IdentityFile ~/.ssh/id_ed25519
```

验证：`ssh dgx-spark` 能直接登录、不要求输入密码。

## 3. 建立 SSH endpoint

在 Mac 上创建一条 `-L`（本地转发）映射：本地端口 -> DGX Spark 的 8888。

CLI 方式：

```bash
# 构建（首次）
make app

# 创建 transport；Local 映射会同时创建一个独立 API endpoint
.build/release/modelmoor init dgx-spark \
  --name dgx-spark \
  --direction local \
  --listen-port 18888 \
  --destination-port 8888 \
  --probe-path /v1/models

# 启动并查看 endpoint
.build/release/modelmoor run dgx-spark
.build/release/modelmoor endpoint list
.build/release/modelmoor models "dgx-spark / LLM API"
```

也可以直接用菜单栏 App：新建 SSH connection，选择 `dgx-spark`，添加一条 Local 映射（listen port `18888`，destination port `8888`），然后连接。ModelMoor 会为它创建 OpenAI-compatible endpoint；SGLang 默认无需 API key。

验证隧道：

```bash
curl http://127.0.0.1:18888/v1/models
# 应返回包含 "qwen3.8-27b-sglang" 的模型列表
```

> 这条 `18888` URL 仍可直接使用，但每增加一台 remote，客户端就要保存一个 URL。下一步用 Local Gateway 把它们统一到固定的 `17777`。

## 4. 加入统一 API

在 ModelMoor 主窗口中：

1. 在 **API Endpoints** 刷新刚创建的 DGX endpoint，确认能看到 `qwen3.8-27b-sglang`。
2. 在 **Unified API / Local Gateway** 添加一条模型映射：公开模型名可仍用 `qwen3.8-27b-sglang`，source endpoint 选择 DGX，upstream model 填同名模型。
3. 启用 Local Gateway，保存并应用。
4. 默认保持 **Require API key** 开启，复制 Unified API URL 和一个已启用的 API key。默认 URL 是 `http://127.0.0.1:17777/v1`。也可以为不同客户端分别创建、启用或停用 key；若明确关闭鉴权，客户端无需填写 key。

以后添加 DeepSeek 时，使用 DeepSeek preset 保存 API key，再为选中的 DeepSeek 模型增加映射即可。商业 key 按 endpoint 分开保存在 macOS Keychain；客户端只拿到 ModelMoor 的 Unified API key。

验证统一模型列表：

```bash
GATEWAY_TOKEN='<从 ModelMoor 复制的 token>'
curl http://127.0.0.1:17777/v1/models \
  -H "Authorization: Bearer $GATEWAY_TOKEN"
```

## 5. 在 VS Code Copilot 中注册模型

编辑（不存在则创建）：

```text
~/Library/Application Support/Code/User/chatLanguageModels.json
```

在数组中追加一个 `customendpoint` 条目：

```json
{
    "name": "DGXSpark",
    "vendor": "customendpoint",
    "apiKey": "<ModelMoor Unified API key>",
    "apiType": "chat-completions",
    "models": [
        {
            "id": "qwen3.8-27b-sglang",
            "name": "Qwen 3.8 27B SGLang",
            "url": "http://127.0.0.1:17777/v1",
            "apiType": "chat-completions",
            "toolCalling": true,
            "vision": true,
            "maxInputTokens": 224000,
            "maxOutputTokens": 32000
        }
    ]
}
```

字段说明：

| 字段              | 说明                                                                                      |
| ----------------- | ----------------------------------------------------------------------------------------- |
| `name` / `vendor` | 端点显示名；`vendor` 固定为 `customendpoint`                                              |
| `apiKey`          | 已启用的 ModelMoor Unified API key；不是 DGX 或商业 API 的 key                            |
| `apiType`         | `chat-completions`，对应 SGLang 的 OpenAI 兼容 `/v1/chat/completions`                     |
| `url`             | 指向 ModelMoor 统一 API；默认固定为 `http://127.0.0.1:17777/v1`                          |
| `toolCalling`     | 开启后 Copilot 可下发工具调用；SGLang 的 `qwen3_coder` parser 会解析为结构化 `tool_calls` |
| `vision`          | Qwen3.8-27B 是原生 VLM，SGLang 直接服务视觉塔，支持图像输入                               |
| `maxInputTokens`  | 原生上下文 262,144；取 224,000 为输出预留空间。若服务端用 YaRN 扩到 1M，可相应调大        |
| `maxOutputTokens` | 单次回复上限，按需调整                                                                    |

可选：让 Copilot 传递推理强度（模型默认 thinking 开启，深度可调）：

```json
"settings": {
    "qwen3.8-27b-sglang": {
        "reasoningEffort": "high"
    }
},
"models": [
    {
        "id": "qwen3.8-27b-sglang",
        "supportsReasoningEffort": ["low", "high", "max"],
        "reasoningEffortFormat": "chat-completions",
        ...
    }
]
```

如果确实需要 SGLang 的原生 Anthropic-compatible `/v1/messages`，请直接使用 `18888` endpoint；首版 Local Gateway 的稳定契约只覆盖 OpenAI-compatible JSON/SSE。

保存后重启 VS Code（或在 Copilot 模型选择器中刷新），模型列表里应出现 **DGXSpark -> Qwen 3.8 27B SGLang**。

## 6. 验证

1. Endpoint：`modelmoor models "dgx-spark / LLM API"`（或在菜单栏 App 中查看模型 ID、延迟等）。
2. 统一 API：

   ```bash
   curl http://127.0.0.1:17777/v1/chat/completions \
     -H "Authorization: Bearer $GATEWAY_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"model": "qwen3.8-27b-sglang",
          "messages": [{"role": "user", "content": "Say ok in one word."}]}'
   ```

3. Copilot 侧：在聊天中选择 `Qwen 3.8 27B SGLang`，发一条消息确认能正常回复；需要工具调用时确认 agent 模式可正常调用工具。

## 常见问题

- **连接被拒绝 / 超时**：依次检查 1) DGX 上 SGLang 是否就绪；2) ModelMoor 的 SSH connection 是否已连接；3) Local Gateway 是否 ready；4) 客户端是否使用 Gateway URL。
- **401**：Require API key 开启时，客户端必须使用一个已启用的 Unified API key；不要填 DGX 占位 key，也不要填 DeepSeek key。
- **模型返回 404**：请求中的 `model` 必须等于 Unified API 中配置的公开模型名。
- **SSH 认证失败**：ModelMoor 使用 `BatchMode=yes`，必须配置好公钥免密登录；密码登录不可用。
- **本地端口被占用**：SSH mapping 的 `18888` 或 Gateway 的 `17777` 都可能冲突；只修改发生冲突的端口。客户端始终跟随 Gateway URL。
- **首次响应慢**：冷启动后首个长 prefill 约 13 s（Triton 内核预热），之后约 8 s，属正常现象。
- **上下文超限**：默认 262K 上下文；长会话报 400 时，缩短上下文或在 DGX 上用 `YARN=1` + `CONTEXT_LENGTH` 扩容（仅 MTP 引擎），并同步调大 `maxInputTokens`。
- **引擎选择**：代码 / agent / 日常对话用 DSpark（`./start-dspark.sh`，代码约 51.5 tok/s）；长文写作用 MTP（`./start.sh`，长文约 24.1 tok/s）。切换需 `./stop.sh` 后重启另一引擎。
