# ModelMoor

> “If there are several ways of doing the same thing, choose one.”

-- <cite>RFC 1958, *Architectural Principles of the Internet* (1996)</cite>

ModelMoor is a native macOS menu bar app and CLI for moving OpenAI-compatible APIs across SSH boundaries and collecting selected models behind one stable local endpoint. It can bring a remote API to your Mac, aggregate SSH-hosted and commercial HTTPS APIs through the authenticated Unified API at `http://127.0.0.1:17777/v1`, and reverse-forward that local Unified API to a remote server when remote tools need to use it.

## Three core workflows

### 1. Bring a remote API to your Mac

Use local SSH port forwarding (`ssh -L`) to turn an API running on a remote server into a stable loopback endpoint on your Mac:

```text
Remote API 127.0.0.1:8888
  | SSH local forward
  v
Mac API    127.0.0.1:18888
```

This is useful for self-hosted vLLM, SGLang, Ollama, or other services that should remain private on the remote machine. ModelMoor manages the SSH process, connection recovery, API health, model discovery, and the local endpoint URL.

### 2. Aggregate remote and commercial APIs locally

Add models from SSH-hosted endpoints and direct HTTPS providers, then assign each one a stable public model name in the Unified API:

```text
SSH-hosted APIs --+
                  +--> ModelMoor Unified API --> http://127.0.0.1:17777/v1
Commercial APIs --+
```

Local clients keep one base URL and one ModelMoor API key. ModelMoor routes each public model name to its exact upstream endpoint, replaces the local credential with that endpoint's Keychain credential, and transparently streams the response. It does not perform fallback, load balancing, or inference retries.

### 3. Make the local Unified API available on a remote server

Some tools run on a remote development or compute server but still need the models collected on your Mac. Use remote SSH port forwarding (`ssh -R`) to carry the local Unified API back through the existing SSH connection:

```text
Mac Unified API 127.0.0.1:17777
  | SSH remote forward
  v
Remote API      127.0.0.1:17777
```

Create the forward with the CLI:

```bash
.build/release/modelmoor add remote-unified-api my-ssh-host \
  --direction remote \
  --listen-port 17777 \
  --destination-port 17777
```

Or add a **Remote port forwarding (-R)** mapping to the SSH connection in the app. A client running on `my-ssh-host` can then use:

```text
Base URL: http://127.0.0.1:17777/v1
API key:  <an enabled ModelMoor Unified API key beginning with sk->
```

The Mac must keep ModelMoor and the SSH connection running. Both listeners remain bound to loopback, so this makes the API available to processes on the selected remote host without exposing it to the remote LAN or the public internet.

## Features

- Discovers SSH targets from `~/.ssh/config` and its recursive `Include` files
- One Mooring uses one SSH process and carries multiple `ssh -L` and `ssh -R` mappings at once
- Models SSH forwarding as a transport and API endpoints separately
- Keeps non-LLM forwarded services in a collapsed **Others** sidebar group instead of reporting API warnings
- Supports direct HTTPS OpenAI-compatible endpoints such as DeepSeek, with one Keychain secret per endpoint
- Connects ChatGPT/Codex, Claude Code, Google Antigravity, Kimi, and xAI/Grok subscription accounts through a bundled, ModelMoor-managed CLIProxyAPI helper
- Keeps that managed helper under the same single runtime-owner boundary as SSH and the Unified API, so a read-only GUI never launches a duplicate process while the CLI or TUI owns the runtime
- Discovers OpenAI-compatible and Ollama models and reports endpoint health independently from SSH state
- Searches SSH connections, endpoints, forwarded services, and discovered model IDs directly from the macOS sidebar
- Localizes critical macOS navigation, commands, status, settings, and update flows in English and Simplified Chinese
- Routes stable public model aliases to exact upstream models without fallback, load balancing, or inference retries
- Serves a loopback-only `/v1/models`, with optional multi-key bearer authentication, and streams OpenAI-compatible responses, including SSE
- Provides a dedicated Usage panel with time, model, and endpoint filters, a token trend chart, and per-model breakdowns
- Checks GitHub Releases for updates from Settings, the menu bar, or the application menu

## Configure the Unified API

Open the ModelMoor main window and:

1. Add a DeepSeek preset or another HTTPS OpenAI-compatible endpoint and save its API key.
2. Create a route, for example `deepseek-fast` -> `deepseek-v4-flash`.
3. Create a Mooring for each SSH remote and route any discovered remote models the same way.
4. Enable **Unified API**, then choose **Save and apply**.
5. Keep **Require API key** on for protected access, then copy an enabled key from **API access**. Add separate keys for different clients when useful.

Any OpenAI-compatible local client can then use:

```text
Base URL: http://127.0.0.1:17777/v1
API key:  <an enabled ModelMoor Unified API key beginning with sk->
```

Verify model discovery:

```bash
curl http://127.0.0.1:17777/v1/models \
  -H "Authorization: Bearer $MODELMOOR_GATEWAY_TOKEN"
```

Send a streaming request. ModelMoor rewrites only the top-level `model`, replaces the local token with the selected endpoint's Keychain credential, and forwards the upstream response:

```bash
curl http://127.0.0.1:17777/v1/chat/completions \
  -H "Authorization: Bearer $MODELMOOR_GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-fast","messages":[{"role":"user","content":"Hello"}],"stream":true}'
```

### Use subscription accounts

Open **Subscription** in the sidebar, then connect ChatGPT/Codex, Claude Code, Google Antigravity, Kimi, or xAI/Grok. Sign-in happens in the provider's browser or device flow; ModelMoor never receives the account password. Add multiple accounts for the same provider when needed, and disable individual accounts without removing their credentials. After models are discovered, configure the models to expose from **Unified API**.

ModelMoor starts the bundled CLIProxyAPI helper only on loopback, gives it a private internal API key and management password from Keychain, monitors its process, and stops it with the app. The public client still uses only the ModelMoor Unified API URL and its ModelMoor API key.

## Requirements

- macOS 14 or later
- Xcode 26 / Swift 6.1 or later (for building from source)
- `rsvg-convert` (`brew install librsvg`) or Inkscape for generating AppIcon PNGs
- Network access on the first app build, to download the pinned CLIProxyAPI release artifact

## Building and Running

The repository keeps only `Resources/Brand/ModelMoor-AppIcon-Master.svg` as the
app-icon source. Missing or stale PNG sizes are generated automatically during
the app build.

```bash
make run
```

`make run` builds and opens the isolated **ModelMoor Dev** app. Its settings, Keychain items, ports, SSH runtime, usage history, and managed CLIProxyAPI data are separate from an installed production version. Use `make app` only when assembling the production-profile app at `.build/app/ModelMoor.app`.

The production build also produces the release CLI and prints its path when done. After moving the production app to `/Applications`, you can enable start at login from the Settings item at the bottom of the ModelMoor sidebar, or press Command-,.

Run `make help` to see all build commands. See [docs/development.md](docs/development.md) for build internals, project layout, and testing.

## CLI

Create a default `-L` mapping:

```bash
.build/release/modelmoor init localhost \
  --name dgx-spark \
  --direction local \
  --listen-port 18888 \
  --destination-port 8888 \
  --probe-path /v1/models
```

Create an initial `-R` mapping. For example, this exposes the Mac's local Unified API on the SSH server's loopback interface:

```bash
.build/release/modelmoor add remote-unified-api my-ssh-host \
  --direction remote \
  --listen-port 17777 \
  --destination-port 17777
```

Create a local SOCKS 4/5 proxy with dynamic port forwarding (`-D`):

```bash
.build/release/modelmoor add local-socks localhost \
  --direction dynamic \
  --listen-port 1080
```

Create a SOCKS 4/5 proxy on the SSH server with reverse dynamic port forwarding
(`-R` without a fixed destination):

```bash
.build/release/modelmoor add remote-socks localhost \
  --direction reverse-dynamic \
  --listen-port 1080
```

The GUI can add more mappings to the same Mooring. The CLI `init` and `add` commands create a single initial mapping.

```text
modelmoor init SSH_HOST [--name NAME] [options]
modelmoor add NAME SSH_HOST [options]
modelmoor list
modelmoor run [NAME]
modelmoor probe [ENDPOINT]
modelmoor endpoint list
modelmoor endpoint url NAME
modelmoor endpoint models NAME
modelmoor url ENDPOINT
modelmoor models ENDPOINT
modelmoor route list
modelmoor gateway url
modelmoor gateway status
modelmoor gateway token --copy
modelmoor ssh-command [NAME]
modelmoor enable NAME
modelmoor disable NAME
modelmoor remove NAME
modelmoor doctor
modelmoor config-path
```

`modelmoor doctor` runs read-only diagnostics over configuration, OpenSSH, SSH transports, endpoints and the Unified API without acquiring the runtime. It prints one tab-separated line per check (`ok`/`warn`/`fail`) and exits with a stable layer code: `0` healthy, `10` configuration, `20` system environment, `30` SSH transport, `40` endpoint authentication, `50` API/protocol, `60` Gateway.

The macOS app also exposes **Copy Diagnostic Summary** from Settings, the Help menu, and the menu-bar menu. This copies the shared bounded runtime event summary; credentials, inference content, and full home-directory paths are redacted.

## TUI

Running `modelmoor` with no subcommand opens the cross-platform terminal console. `--help` and every explicit command remain conventional CLI commands; `modelmoor-tui` remains available as a standalone compatibility executable. The console has Overview, SSH Connections, API Endpoints, Unified API, Needs Attention, and Settings panes. Use Tab or the mouse to move focus and select rows. Pane text is read-only: the bottom `moor>` shell is the only place to enter commands or modify configuration and runtime state.

The shell supports `add ssh`, `add port`, `add api`, `subs`, `gateway`, `connect [name]`, `disconnect [name]`, `filter <terms>`, `clear-filter`, `refresh`, `status`, and `quit`. Enter `help` in the shell for the full list. `r` refreshes, `?` or F1 opens keyboard help, and `q` quits. The terminal UI always uses ASCII glyphs and borders.

The TUI shares the single runtime owner lock with the GUI and `modelmoor run`; it starts read-only and shows the current owner instead of taking over. When stdin/stdout are not TTYs it prints a stable plain-text snapshot and exits; configuration or startup failures write a `modelmoor-tui:` error to stderr and return a nonzero status.

## Linux

The root package (Core/System/Gateway) and the `modelmoor` CLI build and test on Ubuntu 22.04/24.04; `modelmoor-tui` is cross-platform as well. Paths follow XDG (`~/.config/modelmoor`, `~/.local/share/modelmoor`, `$XDG_RUNTIME_DIR`). On Linux, API keys and Unified API keys are stored only after you explicitly enable the owner-only file secret backend (`MODELMOOR_SECRET_BACKEND=file`, optionally `MODELMOOR_SECRETS_FILE=/path`); without it, reads behave as "no secret" and writes fail with guidance — no silent plaintext downgrade. See docs/development.md for the container-based Linux verification workflow.

For testing or automation, set `MODELMOOR_CONFIG=/path/to/config.json` to avoid modifying the real configuration.

Non-secret configuration is stored in XDG-style files so it can be inspected, backed up, or copied between profiles:

```text
~/.config/modelmoor/config.json      # production
~/.config/modelmoor/config.dev.json  # development
```

`XDG_CONFIG_HOME` replaces `~/.config` when it contains an absolute path. On first launch after upgrading, ModelMoor copies the matching legacy `Application Support` configuration into the new location and leaves the old file unchanged. Copying a configuration between profiles does not copy its Keychain credentials.

## Security Boundaries

- SSH passwords, private keys, ProxyJump, and the agent are managed by the system OpenSSH.
- `BatchMode=yes` prevents background connections from prompting for a password.
- Local and remote listener addresses only accept `127.0.0.1` or `localhost`.
- `-R 0.0.0.0:...` and GatewayPorts are not supported yet, to avoid exposing local services to the remote network.
- Endpoint credentials and Unified API key values are stored only in the current user's macOS Keychain. Configuration contains only key names, identifiers, and enabled states.
- The CLIProxyAPI internal API key and management password are generated from Keychain. The helper requires its API key in configuration, so ModelMoor materializes that loopback-only key into a mode-0600 generated config while the management password remains environment-only. OAuth access and refresh tokens for subscription providers are file-backed because CLIProxyAPI requires auth files; they live under `~/Library/Application Support/ModelMoor/CLIProxyAPI/auths` inside directories restricted to the current user. Development builds use the separate `ModelMoor Dev` application-data directory.
- The managed CLIProxyAPI listener and management API bind only to loopback. Remote management is disabled, its control panel is disabled, request logging and upstream retries are disabled, and the management password is passed in memory through the child-process environment rather than written into configuration.
- The Unified API binds only `127.0.0.1`. Bearer authentication is enabled by default, supports multiple independently enabled keys, and can be turned off with an in-app warning. Newly created and rotated keys use the familiar `sk-` prefix; an existing legacy Gateway Token remains valid as the Default key until the user rotates it. Client credentials are removed before ModelMoor injects only the selected endpoint credential.
- API inspection only performs GET probes. The Gateway never logs request or response bodies and never retries or falls back to another paid endpoint.
- Usage history stores only a timestamp, total token count, and internal route/endpoint identifiers. It is based on upstream `usage` fields, so a streaming response is counted only when the upstream includes usage data.
- Gateway requests are limited to 16 MiB and 64 active requests; file, image/audio upload, CORS, and native Anthropic/Gemini protocol translation are intentionally out of scope.
- Subscription routing depends on each provider's current subscription terms and CLIProxyAPI's compatibility layer. It does not convert a consumer subscription into an official metered API entitlement; users remain responsible for provider terms, quotas, and account policy.

## Documentation

- [Development](docs/development.md) - build targets, project layout, and testing.
- [DGX Spark -> Copilot](docs/dgx-spark-copilot.en.md) ([Chinese](docs/dgx-spark-copilot.zh.md)) - serve Qwen3.8-27B on a DGX Spark with SGLang and connect it to VS Code Copilot.

## License

The project is released under the MIT License.
