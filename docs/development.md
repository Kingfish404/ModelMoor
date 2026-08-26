# Development

Internal notes for building, testing, and extending ModelMoor.

For a user-facing walkthrough of serving Qwen3.8-27B on a DGX Spark and wiring it into VS Code Copilot, see [dgx-spark-copilot.en.md](dgx-spark-copilot.en.md) ([中文](dgx-spark-copilot.zh.md)).

## Requirements

- macOS 14 or later
- Xcode 26 / Swift 6.1 or later
- The system OpenSSH client (no bundled SSH implementation)

## Build Commands

All build commands are wrapped by the top-level `Makefile`. Run `make help` for the list.

| Target                    | Description                                                             |
| ------------------------- | ----------------------------------------------------------------------- |
| `make app`                | Build the production app bundle and CLI via `Scripts/build-app.sh`      |
| `make app-dev`            | Build the isolated `ModelMoor Dev` app bundle                           |
| `make build`              | Alias for `make app`                                                    |
| `make cli`                | Build the production CLI only (`swift build -c release`)                |
| `make tui`                | Build the standalone production TUI compatibility executable            |
| `make debug`              | Build debug binaries                                                    |
| `make test`               | Run architecture boundaries, then the root test suite                   |
| `make architecture-check` | Reject forbidden platform, UI, and terminal imports across layers       |
| `make localization-check` | Verify catalog resources and compiler-extracted GUI key coverage        |
| `make run`                | Build and open `ModelMoor Dev` (alias for `make run-dev`)               |
| `make run-release`        | Build and open a production-profile app from `.build`                   |
| `make run-cli ARGS='...'` | Run the debug CLI with optional arguments                               |
| `make run-tui ARGS='...'` | Run the debug TUI with optional arguments                               |
| `make test-root`          | Explicit alias for the root architecture checks and test suite          |
| `make test-app`           | Run the macOS app package tests                                         |
| `make test-tui`           | Run the TUI package tests                                               |
| `make test-cli-signal`    | Verify CLI signal handling and cleanup                                  |
| `make test-cli-tui-terminal` | Verify default CLI TUI terminal behavior                            |
| `make test-tui-terminal`  | Verify TUI resize, signal, and terminal restoration behavior            |
| `make test-all`           | Run all package and terminal integration tests                          |
| `make install`            | Build and replace `/Applications/ModelMoor.app` with the production app |
| `make clean`              | Remove build artifacts (`.build/`)                                      |

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
4. Copies the English and Simplified Chinese app localizations into standard `en.lproj` and `zh-Hans.lproj` bundle resources.
5. Copies SwiftNIO's privacy manifest and the SwiftNIO/CNIOLLHTTP/CLIProxyAPI license notices into the app resources.
6. Signs the CLIProxyAPI child executable before signing the complete app bundle.

The build uses `--disable-sandbox` and a project-local cache (`.build/cache`, `.build/module-cache`) so it works in restricted environments.

`Apps/macOS/Sources/ModelMoor/Resources/Localizable.xcstrings` is the authoritative localization source. SwiftPM command-line builds currently copy that editor catalog instead of compiling it, so the generated `en.lproj` and `zh-Hans.lproj` `Localizable.strings` sidecars remain checked in for runtime compatibility. Run `Scripts/sync-localizations.sh` after editing the catalog. `make localization-check` compiles the catalog with Xcode, compares both sidecars semantically, then uses Swift compiler `.stringsdata` extraction to ensure every static SwiftUI key is present. Technical values and user data must use `Text(verbatim:)` rather than becoming localization keys. Final app assembly copies only the two compiled `.lproj` resources, not the raw catalog.

## Project Layout

```text
Sources/
  ModelMoorCore/     Pure domain: configuration schema v2, validation,
                     migration, cascade rules, diagnostics types, endpoint
                     routing data, tunnel status. Foundation only — no
                     Darwin/Glibc, Security, Network, AppKit or SwiftUI.
  ModelMoorSystem/   Platform adapters: POSIX file/lock IO, atomic writer,
                     OpenSSH command/process supervision, endpoint inspection
                     and release checks (URLSession), platform paths (XDG),
                     secret stores, network monitor, CLIProxyAPI/CodexBar
  ModelMoorGateway/  SwiftNIO loopback server, local authentication, exact model
                     routing, credential isolation, and streaming proxy
  ModelMoorApplication/  Single business entry point: ModelMoorSession actor,
                     AppSnapshot (secret-free), DoctorRunner diagnostics,
                     credential commands. GUI, CLI and TUI share this layer.
  modelmoor/         CLI entry point (subcommands; no arguments opens the TUI)
Apps/
  macOS/             Standalone package for the SwiftUI menu bar app, so the
                     root package stays buildable and testable on Linux
  TUI/               Shared TUI sources and a standalone modelmoor-tui
                     compatibility package (TermKit pinned to a patched revision
                     and SwiftTerm pinned to 1.20.0);
                     TUIWidgets holds the terminal-independent snapshot
                     renderer so tests run without a TTY
Tests/
  ModelMoorCoreTests/  Unit tests for Core + System
  ModelMoorApplicationTests/  Session lifecycle, runtime-owner conflict,
                     doctor layering/exit codes
  ModelMoorGatewayTests/  Router and real loopback/SSE integration tests
Scripts/
  build-app.sh       App bundle assembly (actool + codesign)
  check-layering.sh  Enforce Core/Application/Gateway/CLI/TUI boundaries
  sync-localizations.sh  Generate/check SwiftPM sidecars from the String Catalog
  check-localization-coverage.sh  Verify compiler-extracted GUI key coverage
  test-cli-signal.py  Foreground runtime SIGTERM and cleanup contract
  test-tui-terminal.py  PTY, resize, signal and terminal-restoration contract
  fetch-cliproxyapi.sh  Pinned CLIProxyAPI release download and checksum verification
Support/
  Info.plist         App bundle Info.plist
Resources/
  Assets.xcassets    App icon and asset catalog
```

`ModelMoorCore` is a plain Swift package module shared by the app, CLI, and Gateway. Keep it free of AppKit/SwiftUI/Darwin/Glibc/Security/Network imports — platform capabilities belong in `ModelMoorSystem` behind `#if canImport(...)` shims. `ModelMoorGateway` is an in-process library rather than a daemon and directly depends only on SwiftNIO's `NIOCore`, `NIOPosix`, and `NIOHTTP1` products.

`make architecture-check` enforces these import boundaries before the root tests. It prefers `rg` and falls back to POSIX `grep`, so the same check runs in the minimal Ubuntu CI containers without adding a search-tool dependency. Keep Darwin/Glibc shims, signal handling, platform paths, secrets and other operating-system behavior in `ModelMoorSystem`; TermKit is linked only by the root `ModelMoorTUI` target and sources under `Apps/TUI`.

Business state changes only through `ModelMoorSession` commands (`load`, `saveConfiguration`, `removeTunnel/Endpoint/Mapping`, `startRuntime/stopRuntime`, `connectTunnel/disconnectTunnel`, credential and managed-subscription commands, temporary and saved endpoint inspection, coalesced SSH target discovery, current/historical usage reads, `refreshGateway`, `suspendRuntime/resumeRuntime`); presentation layers subscribe to secret-free `snapshots()`. Endpoint duplication and SSH Endpoint creation copy/store credentials transactionally with rollback, while explicit key-reveal commands return a value only to the invoking pasteboard action. Credential availability is projected as IDs only, so GUI rendering never synchronously calls Keychain and TUI can report missing keys without receiving secrets. The Session also owns CLIProxyAPI process lifecycle, management requests, login polling, bounded restart, account mutation and optional subscription-usage reads through injectable System protocols. GUI, `modelmoor run` and `modelmoor-tui` share one runtime owner lock (`RuntimeOwnership`, flock-based) — the loser stays read-only and subscription mutation controls are disabled rather than launching a second helper.

Presentation-independent interaction policy also lives in `ModelMoorApplication`: GUI and TUI prepare the same terminal-safe, localized multi-field search query once per filtering pass, share SSH command eligibility for tunnel phase, desired runtime identity, and enabled mappings, and use the same endpoint URL/refresh/duplication eligibility. The macOS sidebar builds its tunnel/mapping/endpoint relationship index once per relevant source revision. The TUI likewise caches configuration ID indexes so selection-only input does not scan the complete configuration, and it resolves clipboard targets before moving blocking platform clipboard work off the UI queue.

The macOS app builds from `Apps/macOS` (`swift build --package-path Apps/macOS`); `modelmoor` launches the shared TUI when invoked without a subcommand, while `make tui` builds the standalone compatibility executable. `Scripts/build-app.sh` handles the app + CLI release assembly.

## Linux Support

The root package (Core/System/Gateway + `modelmoor` CLI) builds and tests on Ubuntu 22.04/24.04. Platform notes:

- Paths follow XDG: configuration stays at `~/.config/modelmoor` (or `$XDG_CONFIG_HOME`), data (usage, secrets) under `~/.local/share/modelmoor` (or `$XDG_DATA_HOME`), runtime locks under `$XDG_RUNTIME_DIR/modelmoor` with a `/tmp/modelmoor-<uid>` fallback.
- Secrets: macOS uses the Keychain. On Linux there is no silent plaintext fallback — set `MODELMOOR_SECRET_BACKEND=file` to explicitly enable the owner-only `0600` file backend (optionally `MODELMOOR_SECRETS_FILE=/path`). A Secret Service adapter is planned once its D-Bus dependency passes the vetting gate in docs/PLAN.md §7.
- Network monitoring: the tunnel supervision loop relies on SSH retry/backoff; `NetworkMonitor` reports availability once and does not track link changes on Linux yet.
- Configuration writes are serialized across processes with a blocking flock on `config.json.lock` and compare-and-swapped against a sidecar revision counter (`config.json.revision`); a stale writer gets `ConfigurationError.revisionConflict` instead of overwriting newer content. Both files are ignored by older versions, keeping the format rollback-safe.

### Local Linux verification via Docker (Apple Silicon host)

Docker Hub may be unreachable; the checked-in workflow uses a plain Ubuntu base plus the official Swift tarball. `Scripts/Dockerfile.linux-swift` covers 24.04 and `Scripts/Dockerfile.linux-swift-22.04` covers 22.04 (different gcc/libstdc++ generations):

```bash
# One-time: download/extract the toolchain (kept out of git via .gitignore)
curl -sL -o work/toolchains/swift-6.1.2-ubuntu24.04-aarch64.tar.gz \
  https://download.swift.org/swift-6.1.2-release/ubuntu2404-aarch64/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-ubuntu24.04-aarch64.tar.gz
tar xzf work/toolchains/swift-6.1.2-ubuntu24.04-aarch64.tar.gz -C work/toolchains

# One-time: base image with Swift runtime/build dependencies
docker build -f Scripts/Dockerfile.linux-swift -t modelmoor-linux-base:24.04 Scripts

# Build + test (named volume caches the SwiftPM scratch dir across runs)
docker run --rm --platform linux/arm64 \
  -v "$PWD:/src:ro" \
  -v "$PWD/work/toolchains/swift-6.1.2-RELEASE-ubuntu24.04-aarch64:/swift:ro" \
  -v mm-linux-scratch:/tmp/scratch-root \
  -w /src modelmoor-linux-base:24.04 \
  /swift/usr/bin/swift test --scratch-path /tmp/scratch-root/main
```

For 22.04, substitute the `ubuntu2204-aarch64` tarball, `Scripts/Dockerfile.linux-swift-22.04` and a separate scratch volume (e.g. `mm-linux-scratch-2204`). For x86_64 verification, use the non-aarch64 tarballs and `--platform linux/amd64`.

As of 2026-08-23, the read-only ARM64 container matrix passes 114 root tests and 19 TUI tests on both Ubuntu 22.04 and 24.04, plus release builds of `modelmoor` and `modelmoor-tui`, the full TUI PTY contract, and the foreground CLI SIGTERM contract. The local verification images include Python/ncurses; the GitHub workflow installs the same runtime dependencies in its official Swift containers. Only a run for the exact revision under review counts as remote CI evidence.

### Linux release artifacts

Pushing a version tag matching `v*` runs the release workflow on native Ubuntu x86_64 and aarch64 runners. Each Linux archive contains the release `modelmoor` CLI, `modelmoor-tui`, `LICENSE`, and `README.md`:

- `ModelMoor-vX.Y.Z-linux-x86_64.tar.gz`
- `ModelMoor-vX.Y.Z-linux-aarch64.tar.gz`

Linux release executables are built on the Ubuntu 22.04 ABI baseline with `--static-swift-stdlib`, so the same archive runs on Ubuntu 22.04 and 24.04 without installing a Swift toolchain or copying `libswift*.so`, Foundation, Dispatch, or BlocksRuntime libraries beside the executables. The executables still dynamically link system libraries (including glibc, libcurl, and its TLS dependencies); release CI rejects missing dependencies and any accidental Swift runtime `.so` dependency with `Scripts/check-linux-release-dependencies.sh`.

The macOS archive is built in parallel; a final publish job creates one GitHub Release only after all three platform archives are available.

## Testing

```bash
make test
make localization-check
swift test --package-path Apps/macOS
swift test --package-path Apps/TUI
python3 Scripts/test-tui-terminal.py "$(swift build --package-path Apps/TUI --show-bin-path)/modelmoor-tui"
python3 Scripts/test-cli-signal.py "$(swift build -c release --show-bin-path)/modelmoor"
```

Tests cover schema migration and rollback, configuration validation, SSH lifecycle and ownership, endpoint URL/auth behavior, route validation, local Gateway authentication and errors, ordinary JSON/error pass-through without retries, listener conflicts and release, client cancellation, upstream-reported usage extraction for JSON and SSE, indexed rolling windows, time buckets, route/endpoint filters, Session-owned managed-subscription lifecycle/login/cancellation/account mutation/usage/sleep recovery with fake helper and management adapters, ordered coordinator/revision filtering for cross-actor subscription snapshots, coalesced SSH target scans, temporary inspection isolation, ID-only credential availability, rollback-safe Endpoint duplication and SSH Endpoint creation, shared prepared search documents with field-boundary and control-character safety, linear macOS sidebar indexing with source/query cache invalidation, prepared-query performance, sidebar hidden-selection recovery without invalid controls, cached 10,000-row TUI filtering, filter/reorder/delete-safe TUI selection identity, phase/request/mapping-aware SSH and resolution/credential-aware endpoint TUI state, bounded trailing TUI refresh coalescing with reload-intent merging and cancellation, shared endpoint copy/refresh, subscription ownership and selected/batch SSH command eligibility across GUI and TUI surfaces, real AppKit window close behavior for dirty drafts, pre-mount and repeated native sidebar-search focus, keyboard navigation mappings, active-window refresh policy, authoritative String Catalog parity and compiler-extracted English/Simplified Chinese coverage, TUI snapshot and field-level invalidation, pane-scoped work policies, non-TTY success and failure exit contracts, small-terminal resize/signal/restoration, foreground CLI signal registration/cleanup, and a real loopback SSE stream that must deliver its first event before the upstream finishes.

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
