# User guide

For installation and the first endpoint, start with the [README](../README.md).

## SSH connections

ModelMoor reads hosts from `~/.ssh/config`, including `Include` files. Verify that `ssh my-ssh-host` works first; background connections use `BatchMode=yes` and cannot prompt for a password. OpenSSH owns keys, the agent, and ProxyJump.

One connection can carry local (`-L`), remote (`-R`), local SOCKS (`-D`), and remote SOCKS (`-R` without a destination) mappings. All listener addresses are loopback-only.

To reuse a local forward, choose **Add API Endpoint > Existing SSH port**, or **Import as API Endpoint** in SSH connection details. Importing links an endpoint to the mapping without creating another tunnel. Disconnected mappings can be imported and checked later.

The app checks active fixed local forwards at `/v1/models` and `/api/tags`. A valid model list identifies an OpenAI-compatible or Ollama API; authentication errors do not confirm the protocol. SOCKS and remote forwards are excluded. Use **Run Diagnostics** to retry detection; HTTPS and custom paths require manual endpoint configuration.

Adding mappings to a connected configuration keeps existing forwards open and reuses its SSH master. Installation normally starts within one second, plus SSH setup time. If any addition fails, that batch is rolled back and retried every five seconds while existing forwards stay active. Pending mappings are excluded from automatic checks and Unified API routing. Editing or removing existing mappings, or changing other connection settings, reconnects the tunnel.

To make your local Unified API available on a remote host:

```bash
modelmoor add remote-unified-api my-ssh-host \
  --direction remote --listen-port 17777 --destination-port 17777
```

Keep the Mac and connection running. Remote clients use `http://127.0.0.1:17777/v1` and a ModelMoor key; the listener is not exposed to the remote LAN.

## Models and clients

In **Unified API > Add Models**, select discovered models or enter an upstream model ID manually. Public names must be unique. Search filters the list; **Select visible** preserves earlier selections. Renaming a public model requires clients to update that name. Removing a route leaves the upstream model intact.

Keep **Require API key** enabled for protected access. You can create separate keys for clients. ModelMoor removes the client credential and supplies only the selected endpoint's credential upstream. **Connect a client** generates examples using the configured port and alias without embedding stored secrets.

After setting `OPENAI_API_KEY` to an enabled ModelMoor key, verify the model list:

```bash
curl http://127.0.0.1:17777/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY"
```

Requests route to one exact upstream model, without automatic fallback or retries. The request-body limit is 16 MiB. File and media uploads, browser CORS, and general Anthropic/Gemini protocol conversion are not supported.

## Subscription accounts

Use **Subscription** to sign in to ChatGPT/Codex, Claude, Kimi Code, or Grok Build, then expose selected models through Unified API.

| Provider | Request path | Requirement |
| --- | --- | --- |
| ChatGPT/Codex | Native Responses API | ModelMoor-managed OAuth |
| Claude, Kimi Code, Grok Build | Text-only Chat Completions | The genuine provider CLI installed locally |

CLI routes disable tools and use isolated temporary profiles. ModelMoor does not read or change local agent credentials. Antigravity login is unsupported. CLIProxyAPI is no longer used; migration disables its old configuration and retains old helper files untouched. Provider terms, quotas, and account restrictions still apply; consumer subscriptions are not metered API entitlements.

## Usage and budgets

The **Usage** panel filters token history by time, model, and endpoint. The model's sliders button sets daily, weekly, and monthly token or USD thresholds. Limits are off by default and **produce warnings only; they do not block requests**. USD estimates require configured input/output prices per million tokens.

Periods use UTC days, ISO weeks starting Monday, and calendar months. Only requests through this runtime with upstream `usage` data are counted, including supported JSON/SSE responses. Missing usage or unavailable storage produces a warning. Estimates exclude unreported charges and cached-token discounts; they are not provider balances, invoices, or spending caps. Historical costs are not reconstructed when prices are added later.

Counters persist in `model-budgets.json` beside token history; disabling limits does not erase counters. SSH byte accounting is separate: see [SSH data usage](data-usage.md).

## CLI and diagnostics

Use `modelmoor --help` or `<command> --help` for the complete command reference.

| Task | Command |
| --- | --- |
| Inspect connections | `modelmoor list`, `modelmoor ssh-command NAME` |
| Run tunnels | `modelmoor run [NAME]` |
| Inspect endpoints | `modelmoor probe`, `modelmoor endpoint models NAME` |
| Get client settings | `modelmoor gateway url`, `modelmoor gateway token --copy` |
| Diagnose failures | `modelmoor doctor` |
| Find configuration | `modelmoor config-path` |

`doctor` is read-only and does not acquire the runtime. Exit codes identify the failing layer: `0` healthy, `10` configuration, `20` system, `30` SSH, `40` endpoint authentication, `50` API/protocol, `60` Unified API. The app's **Copy Diagnostic Summary** redacts credentials, inference content, and full home paths.

Running `modelmoor` without arguments opens the TUI; `modelmoor-tui` is the standalone equivalent. Enter commands in the bottom `moor>` shell and use `help` for operations. It starts read-only when another process owns the runtime. Without a TTY it prints a plain-text snapshot and exits; startup failures return a nonzero status.

## Configuration and credentials

| macOS resource | Production | Development |
| --- | --- | --- |
| Configuration | `~/.config/modelmoor/config.json` | `~/.config/modelmoor/config.dev.json` |
| Secrets | `~/.config/modelmoor/secrets.json` | `~/.config/modelmoor-dev/secrets.json` |
| History | `~/Library/Application Support/ModelMoor` | `~/Library/Application Support/ModelMoor Dev` |
| Default API port | `17777` | `27777` |

`XDG_CONFIG_HOME` replaces `~/.config` when absolute. `MODELMOOR_CONFIG` overrides configuration only; `MODELMOOR_SECRETS_FILE` independently overrides secrets, and `MODELMOOR_USAGE` overrides token history. Sharing a secrets override shares credentials between profiles. These overrides do not isolate the macOS runtime owner lock.

On Linux, configuration follows XDG and data defaults to `~/.local/share/modelmoor`. Set `MODELMOOR_SECRET_BACKEND=file` to allow secret writes; there is no silent fallback. `XDG_DATA_HOME` and `XDG_RUNTIME_DIR` control the corresponding Linux paths.

After editing configuration externally, use **Reload Configuration**. Discard unapplied form changes to load the file without saving those changes first. Invalid input leaves the active configuration unchanged. Legacy configuration is copied to the new location only if the destination does not exist; the original is preserved. Configuration copies do not include credentials.

Secrets are plaintext JSON protected by directory mode `0700`, file mode `0600`, atomic writes, and locking, not encryption. Processes running as your user and administrators can read them. Keep secrets out of source control and shared or unencrypted backups. Unsafe ownership, permissions, and symlinks are rejected. Historical Keychain credentials are not read or migrated; re-enter keys stored only there.

HTTP sends credentials without encryption; use HTTPS except on loopback or trusted networks. ModelMoor does not log inference bodies. Token history contains timestamps, token totals, and internal route/endpoint IDs; SSH history contains byte counts and internal path IDs. ModelMoor provides no public listener, multi-user billing, or telemetry.