# Development

Internal notes for building, testing, and extending ModelMoor.

For a user-facing walkthrough of serving Qwen3.8-27B on a DGX Spark and wiring it into VS Code Copilot, see [dgx-spark-copilot.en.md](dgx-spark-copilot.en.md) ([中文](dgx-spark-copilot.zh.md)).

## Requirements

- macOS 14 or later
- Xcode 26 / Swift 6.1 or later
- The system OpenSSH client (no bundled SSH implementation)

## Build Commands

All build commands are wrapped by the top-level `Makefile`. Run `make help` for the list.

| Target             | Description                                                             |
| ------------------ | ----------------------------------------------------------------------- |
| `make app`         | Build the production app bundle and CLI via `Scripts/build-app.sh`      |
| `make app-dev`     | Build the isolated `ModelMoor Dev` app bundle                           |
| `make build`       | Alias for `make app`                                                    |
| `make cli`         | Build the production CLI only (`swift build -c release`)                |
| `make debug`       | Build debug binaries                                                    |
| `make test`        | Run the test suite (`swift test`)                                       |
| `make run`         | Build and open `ModelMoor Dev` (alias for `make run-dev`)               |
| `make run-release` | Build and open a production-profile app from `.build`                   |
| `make install`     | Build and replace `/Applications/ModelMoor.app` with the production app |
| `make clean`       | Remove build artifacts (`.build/`)                                      |

`make app` produces:

- `.build/app/ModelMoor.app` — the menu bar app bundle
- `.build/app-dev/ModelMoor Dev.app` — the isolated development app bundle
- `.build/release/modelmoor` — the CLI binary (path is printed at the end of the build)

## Production and Development Isolation

The app bundle declares a build profile in `Info.plist`. Both profiles use the same compiled Swift executable, but resolve separate runtime resources:

| Resource                 | Production                                | Development                                   |
| ------------------------ | ----------------------------------------- | --------------------------------------------- |
| App identity             | `ModelMoor` / `com.modelmoor.app`         | `ModelMoor Dev` / `com.modelmoor.app.dev`     |
| Non-secret configuration | `~/.config/modelmoor/config.json`         | `~/.config/modelmoor/config.dev.json`         |
| Application data         | `~/Library/Application Support/ModelMoor` | `~/Library/Application Support/ModelMoor Dev` |
| Keychain service         | `com.modelmoor.api-token`                 | `com.modelmoor.dev.api-token`                 |
| Runtime and SSH controls | `/tmp/modelmoor-UID`                      | `/tmp/modelmoor-dev-UID`                      |
| Unified API default      | `127.0.0.1:17777`                         | `127.0.0.1:27777`                             |
| CLIProxyAPI default      | `127.0.0.1:18317`                         | `127.0.0.1:28317`                             |

Development builds disable login launch and update checks. The production profile can read the legacy `dev.modelmoor.api-token` Keychain service used by v0.1.0 for upgrade compatibility, but new or changed secrets are written under `com.modelmoor.api-token`.

`XDG_CONFIG_HOME` replaces `~/.config` when it is an absolute path. `MODELMOOR_CONFIG` has higher priority than both profile defaults and disables automatic legacy import. The Settings page lists the active configuration, retained legacy configuration, usage history, CLIProxyAPI data, app preferences, and Keychain service with system-native open actions.

## App Bundle Assembly

`Scripts/build-app.sh` assembles the app bundle on top of `swift build -c release`:

1. Copies the `ModelMoor` binary and `Support/Info.plist` into the bundle.
2. Downloads the architecture-specific, checksum-pinned CLIProxyAPI release on first use and copies it into `Contents/MacOS`.
3. Compiles `Resources/Assets.xcassets` with `actool` (app icon, minimum deployment target 14.0).
4. Copies SwiftNIO's privacy manifest and the SwiftNIO/CNIOLLHTTP/CLIProxyAPI license notices into the app resources.
5. Signs the CLIProxyAPI child executable before signing the complete app bundle.

The build uses `--disable-sandbox` and a project-local cache (`.build/cache`, `.build/module-cache`) so it works in restricted environments.

## Project Layout

```text
Sources/
  ModelMoorCore/     Core logic: configuration, SSH command building, tunnel
                     service, endpoint routing data, API inspection, Keychain
                     token storage, migration, diagnostics, runtime ownership
  ModelMoorGateway/  SwiftNIO loopback server, local authentication, exact model
                     routing, credential isolation, and streaming proxy
  ModelMoorApp/      SwiftUI menu bar app: app lifecycle, main window,
                     settings, menu bar view
  modelmoor/         CLI entry point (Sources/modelmoor/main.swift)
Tests/
  ModelMoorCoreTests/  Unit tests for ModelMoorCore
  ModelMoorGatewayTests/  Router and real loopback/SSE integration tests
Scripts/
  build-app.sh       App bundle assembly (actool + codesign)
  fetch-cliproxyapi.sh  Pinned CLIProxyAPI release download and checksum verification
Support/
  Info.plist         App bundle Info.plist
Resources/
  Assets.xcassets    App icon and asset catalog
```

`ModelMoorCore` is a plain Swift package module shared by the app, CLI, and Gateway. Keep it free of AppKit/SwiftUI dependencies. `ModelMoorGateway` is an in-process library rather than a daemon and directly depends only on SwiftNIO's `NIOCore`, `NIOPosix`, and `NIOHTTP1` products.

## Testing

```bash
make test
```

Tests cover schema migration and rollback, configuration validation, SSH lifecycle and ownership, endpoint URL/auth behavior, route validation, local Gateway authentication and errors, ordinary JSON/error pass-through without retries, listener conflicts and release, client cancellation, upstream-reported usage extraction for JSON and SSE, rolling windows, time buckets, route/endpoint filters, and a real loopback SSE stream that must deliver its first event before the upstream finishes.

Set `MODELMOOR_CLIPROXY_BINARY` to the pinned helper path printed by `Scripts/fetch-cliproxyapi.sh` when running the optional real-process sidecar smoke test. That test starts CLIProxyAPI on a temporary loopback port, authenticates its management API, and shuts it down.

## Software Updates

The app checks `Kingfish404/ModelMoor` GitHub Releases. Release tags must be numeric versions such as `v0.2.0`, and the app bundle's `CFBundleShortVersionString` must match the corresponding version. If a release contains a `.dmg` or `.zip` asset whose name includes `ModelMoor`, the update action opens that asset directly; otherwise it opens the release page. Automatic checks are enabled by default and run every three hours while the app is open.

## Configuration Schema

The non-secret configuration files live at:

```text
~/.config/modelmoor/config.json
~/.config/modelmoor/config.dev.json
```

For testing or automation, set `MODELMOOR_CONFIG=/path/to/config.json` to point the app or CLI at an alternate configuration file. The CLI uses the production filename by default.

When the selected XDG file does not exist, ModelMoor copies the matching legacy file from `~/Library/Application Support/ModelMoor*/config.json`, then performs schema migration only on the new copy. The legacy file is never moved, overwritten, or deleted. If the XDG file already exists, it always wins.

Schema v3 keeps SSH port mappings, API endpoints, public model routes, Unified API settings, and managed CLIProxyAPI settings separate. Secrets are never serialized: endpoint keys use the endpoint UUID as their Keychain account. Unified API key metadata is stored in configuration, while each value uses its key UUID as a Keychain account. The migrated default key continues to use the legacy `gateway-client-token` account.

Unified API usage history lives at `~/Library/Application Support/ModelMoor/token-usage.jsonl`. Each line contains only a timestamp, a total token count reported by an upstream response, and internal route/endpoint identifiers used by the Usage filters. Set `MODELMOOR_USAGE=/path/to/token-usage.jsonl` to isolate this file in tests or automation.
