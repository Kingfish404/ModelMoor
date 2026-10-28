# ModelMoor

ModelMoor is a native macOS menu bar app, CLI, and terminal console for connecting private SSH-hosted and direct HTTP(S) model APIs. Expose selected models through one local **Unified API**, or forward that API to a remote machine over SSH.

- Bring remote services to your Mac with local SSH forwarding; reuse existing forwards as API endpoints.
- Give models stable public aliases behind `http://127.0.0.1:17777/v1`, with separate upstream credentials and streaming responses.
- Connect supported subscription accounts and inspect model, token, and SSH data usage.

ModelMoor is single-user and loopback-only. It uses system OpenSSH, stores credentials separately from configuration, and has no telemetry or ModelMoor cloud account. Routing is exact, without fallback, load balancing, or inference retries.

## Get started

Download from [GitHub Releases](https://github.com/Kingfish404/ModelMoor/releases/latest). The macOS app requires macOS 14 or later; Linux CLI/TUI archives support Ubuntu 22.04 and 24.04.

1. Choose **Add API Endpoint** and select a direct HTTP(S) API, a new SSH connection, or an existing SSH port. Test and save it.
2. Open **Unified API**, enable it, and choose **Add Models**. Select models and assign the public names clients will use.
3. Copy an enabled key from **API access**. Under **Connect a client**, copy the base URL and a request example.

```text
Base URL: http://127.0.0.1:17777/v1
API key:  <your ModelMoor Unified API key>
Model:    <your public model name>
```

Each endpoint can also be used directly. For Ollama through Unified API, use its OpenAI-compatible `/v1` endpoint; the native Ollama preset is for discovery.

## CLI and TUI

Run `modelmoor` without arguments to open the terminal console. Use `modelmoor --help` for commands and `help` inside the console.

```bash
modelmoor init my-ssh-host --name lab \
  --listen-port 18888 --destination-port 8888 --probe-path /v1/models
modelmoor run lab
```

The app, CLI runtime, and TUI share one runtime owner lock. On Linux, explicitly enable secret storage with `MODELMOOR_SECRET_BACKEND=file` before saving API keys.

## Build from source

On macOS, install Xcode 26 / Swift 6.1 or later and `librsvg` (`brew install librsvg`) or Inkscape for icon generation, then run:

```bash
make run
```

This builds and opens **ModelMoor Dev**, isolated from production settings, credentials, ports, and history. Use `make app` for a production app bundle; `make help` lists other targets.

## Documentation

- [User guide](docs/usage.md): SSH forwarding, subscriptions, budgets, CLI, configuration, and security.
- [DGX Spark to VS Code Copilot](docs/dgx-spark-copilot.en.md) / [中文教程](docs/dgx-spark-copilot.zh.md): a complete SGLang setup.
- [Development](docs/development.md): builds, tests, architecture, and releases.
- [SSH data accounting](docs/data-usage.md): what byte counts measure and how history is stored.

## License

[MIT](LICENSE).