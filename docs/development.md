# Development

Internal notes for building, testing, and extending ModelMoor.

For a user-facing walkthrough of serving Qwen3.8-27B on a DGX Spark and wiring it into VS Code Copilot, see [dgx-spark-copilot.en.md](dgx-spark-copilot.en.md) ([中文](dgx-spark-copilot.zh.md)).

## Requirements

- macOS 14 or later
- Xcode 26 / Swift 6.1 or later
- The system OpenSSH client (no bundled SSH implementation)

## Build Commands

All build commands are wrapped by the top-level `Makefile`. Run `make help` for the list.

| Target               | Description                                                     |
| -------------------- | --------------------------------------------------------------- |
| `make app` (default) | Build the release app bundle and CLI via `Scripts/build-app.sh` |
| `make build`         | Alias for `make app`                                            |
| `make cli`           | Build the release CLI only (`swift build -c release`)           |
| `make debug`         | Build debug binaries                                            |
| `make test`          | Run the test suite (`swift test`)                               |
| `make run`           | Build and open the app                                          |
| `make install`       | Build and install to `/Applications`                            |
| `make clean`         | Remove build artifacts (`.build/`)                              |

`make app` produces:

- `.build/app/ModelMoor.app` — the menu bar app bundle
- `.build/release/modelmoor` — the CLI binary (path is printed at the end of the build)

## App Bundle Assembly

`Scripts/build-app.sh` assembles the app bundle on top of `swift build -c release`:

1. Copies the `ModelMoor` binary and `Support/Info.plist` into the bundle.
2. Compiles `Resources/Assets.xcassets` with `actool` (app icon, minimum deployment target 14.0).
3. Copies SwiftNIO's privacy manifest and the SwiftNIO/CNIOLLHTTP license notices into the app resources.
4. Ad-hoc signs the bundle with `codesign --force --deep --sign -`.

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

## Configuration Schema

The configuration file lives at:

```text
~/Library/Application Support/ModelMoor/config.json
```

For testing or automation, set `MODELMOOR_CONFIG=/path/to/config.json` to point the CLI at an alternate configuration file.

Schema v2 keeps SSH port mappings, API endpoints, public model routes, and Unified API settings separate. Secrets are never serialized: endpoint keys use the endpoint UUID as their Keychain account. Unified API key metadata is stored in configuration, while each value uses its key UUID as a Keychain account. The migrated default key continues to use the legacy `gateway-client-token` account.

Unified API usage history lives at `~/Library/Application Support/ModelMoor/token-usage.jsonl`. Each line contains only a timestamp, a total token count reported by an upstream response, and internal route/endpoint identifiers used by the Usage filters. Set `MODELMOOR_USAGE=/path/to/token-usage.jsonl` to isolate this file in tests or automation.
