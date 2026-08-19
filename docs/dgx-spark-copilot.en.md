# Guide: DGX Spark (Qwen3.8-27B SGLang) -> VS Code Copilot

> 语言 / Language: [中文](dgx-spark-copilot.zh.md) / [English (this document)](dgx-spark-copilot.en.md)

Serve Qwen3.8-27B with [SGLang](https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark) on an NVIDIA DGX Spark, connect it through ModelMoor's SSH transport, and expose it through one local OpenAI-compatible API. The same API can also include models from DeepSeek and other commercial endpoints.

```text
DGX Spark (SGLang :8888)
        |  SSH (system OpenSSH, managed by ModelMoor)
        v
macOS local port (e.g. 18888)
        |                         DeepSeek / other HTTPS API + Keychain key
        +-----------------------------+
                                      v
ModelMoor Local Gateway (http://127.0.0.1:17777/v1)
        |  one URL, one local bearer token, stable model aliases
        v
VS Code Copilot (custom endpoint in chatLanguageModels.json)
```

## 1. Start the SGLang server on the DGX Spark

Reference repo: <https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark>

Requirements:

- NVIDIA DGX Spark / GB10 (aarch64, 128 GB unified memory)
- Docker + NVIDIA Container Toolkit (`docker run --gpus all` working)
- `docker`, `curl`; `HF_TOKEN` defined in `~/.bashrc` (higher Hugging Face rate limits)

Quick start:

```bash
git clone https://github.com/MiaAI-Lab/Qwen3.8-27B-SGLang-DGX-Spark
cd Qwen3.8-27B-SGLang-DGX-Spark
cp .env.sample .env          # first run: creates .env (defaults: 262K context, 10 concurrent)

./start-dspark.sh           # DSpark engine: faster for code/agents (recommended default)
# ./start.sh                # or the MTP engine: faster for long-form writing

curl http://127.0.0.1:8888/v1/models   # returns the model list once the server is ready
```

Key points:

- The server listens on `0.0.0.0:8888` (host networking); the OpenAI-compatible base URL is `http://<DGX-IP>:8888/v1`.
- The served model name is `qwen3.8-27b-sglang`.
- First start downloads ~22 GB of weights into `./.cache/huggingface`; the DSpark engine additionally fetches a ~2.7 GB draft model.
- Thinking mode (`reasoning_content`) and tool calling (`qwen3_coder` parser) are on by default — no extra flags needed.
- Native context is 262,144 tokens; extend to 1M with `YARN=1` + `CONTEXT_LENGTH` (MTP engine only — DSpark does not support YaRN).
- Stop the server with `./stop.sh`.

## 2. Configure the SSH host

ModelMoor discovers targets from `~/.ssh/config` and its recursive `Include` files. Make sure there is a Host entry for the DGX Spark with key-based (passwordless) auth — ModelMoor uses `BatchMode=yes`, so background connections will never prompt for a password:

```ssh-config
Host dgx-spark
    HostName 192.168.x.x
    User <your-username>
    IdentityFile ~/.ssh/id_ed25519
```

Verify: `ssh dgx-spark` logs in directly without asking for a password.

## 3. Create the SSH endpoint

On the Mac, create a `-L` (local forward) mapping: local port -> port 8888 on the DGX Spark.

Via the CLI:

```bash
# build (first time)
make app

# create the transport; a Local mapping also creates a separate API endpoint
.build/release/modelmoor init dgx-spark \
  --name dgx-spark \
  --direction local \
  --listen-port 18888 \
  --destination-port 8888 \
  --probe-path /v1/models

# start and inspect the endpoint
.build/release/modelmoor run dgx-spark
.build/release/modelmoor endpoint list
.build/release/modelmoor models "dgx-spark / LLM API"
```

Or use the menu bar app directly: create an SSH connection, pick host `dgx-spark`, add a Local mapping (listen port `18888`, destination port `8888`), then connect. ModelMoor creates an OpenAI-compatible endpoint for it; SGLang does not require an API key by default.

Verify the tunnel:

```bash
curl http://127.0.0.1:18888/v1/models
# should return the model list containing "qwen3.8-27b-sglang"
```

> You can still use the `18888` URL directly, but each additional remote would require another client URL. The Local Gateway in the next step keeps the client URL fixed at `17777`.

## 4. Add it to the unified API

In the ModelMoor main window:

1. Refresh the DGX entry under **API Endpoints** and confirm that it discovers `qwen3.8-27b-sglang`.
2. Under **Unified API / Local Gateway**, add a model mapping. Keep `qwen3.8-27b-sglang` as the public model name, select the DGX source endpoint, and use the same upstream model ID.
3. Enable Local Gateway, then save and apply.
4. Keep **Require API key** on by default, then copy the Unified API URL and one enabled API key. The default URL is `http://127.0.0.1:17777/v1`. You can create, enable, or disable separate keys for each client; if you explicitly turn authentication off, clients do not need a key.

To add DeepSeek later, use the DeepSeek preset, save its API key, and map any desired DeepSeek models. Commercial keys remain separated per endpoint in the macOS Keychain; the client receives only a ModelMoor Unified API key.

Verify the unified model list:

```bash
GATEWAY_TOKEN='<token copied from ModelMoor>'
curl http://127.0.0.1:17777/v1/models \
  -H "Authorization: Bearer $GATEWAY_TOKEN"
```

## 5. Register the model in VS Code Copilot

Edit (or create) this file:

```text
~/Library/Application Support/Code/User/chatLanguageModels.json
```

Append a `customendpoint` entry to the array:

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

Field notes:

| Field | Description |
| --- | --- |
| `name` / `vendor` | Display name for the endpoint; `vendor` is always `customendpoint` |
| `apiKey` | An enabled ModelMoor Unified API key, not a DGX or commercial API key |
| `apiType` | `chat-completions`, matching SGLang's OpenAI-compatible `/v1/chat/completions` |
| `url` | Points at ModelMoor's unified API; the default is `http://127.0.0.1:17777/v1` |
| `toolCalling` | When enabled, Copilot can send tool calls; SGLang's `qwen3_coder` parser decodes them into structured `tool_calls` |
| `vision` | Qwen3.8-27B is a native VLM; SGLang serves the vision tower live, so image input works |
| `maxInputTokens` | Native context is 262,144; 224,000 leaves headroom for output. Raise it if the server is extended to 1M via YaRN |
| `maxOutputTokens` | Per-response cap; adjust to taste |

Optional: let Copilot pass a reasoning effort (thinking is on by default; depth is tunable):

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

If you specifically need SGLang's native Anthropic-compatible `/v1/messages`, use the `18888` endpoint directly. The first Local Gateway contract covers only OpenAI-compatible JSON/SSE.

After saving, restart VS Code (or refresh the Copilot model picker) — the model list should now show **DGXSpark -> Qwen 3.8 27B SGLang**.

## 6. Verify

1. Endpoint: `modelmoor models "dgx-spark / LLM API"` (or inspect the model ID and latency in the menu bar app).
2. Unified API:

   ```bash
   curl http://127.0.0.1:17777/v1/chat/completions \
     -H "Authorization: Bearer $GATEWAY_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"model": "qwen3.8-27b-sglang",
          "messages": [{"role": "user", "content": "Say ok in one word."}]}'
   ```

3. Copilot side: pick `Qwen 3.8 27B SGLang` in the chat and send a message to confirm it replies; in agent mode, confirm tool calls work.

## Troubleshooting

- **Connection refused / timeout**: check in order 1) SGLang is up on the DGX; 2) the ModelMoor SSH connection is connected; 3) Local Gateway is ready; 4) the client uses the Gateway URL.
- **401**: while Require API key is on, the client must use an enabled Unified API key. Do not use a DGX placeholder key or a DeepSeek key.
- **Model returns 404**: the request's `model` must exactly match its public name in Unified API.
- **SSH auth failure**: ModelMoor uses `BatchMode=yes`, so key-based passwordless login is required; password login will not work.
- **Local port in use**: either the SSH mapping's `18888` or the Gateway's `17777` can conflict. Change only the conflicting port; clients should continue to follow the Gateway URL.
- **Slow first response**: the first long prefill after a cold boot takes ~13 s (Triton kernel warmup), then ~8 s — this is normal.
- **Context overflow**: the default context is 262K; if long sessions return 400, shorten the context or extend it on the DGX with `YARN=1` + `CONTEXT_LENGTH` (MTP engine only), and raise `maxInputTokens` accordingly.
- **Engine choice**: use DSpark (`./start-dspark.sh`, ~51.5 tok/s on code) for code / agents / everyday chat; use MTP (`./start.sh`, ~24.1 tok/s on long essays) for long-form writing. Switching requires `./stop.sh` followed by the other start script.
