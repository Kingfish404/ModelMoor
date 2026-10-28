# Development

User-facing setup and storage details live in the [user guide](usage.md); this page covers contributing and releasing.

## Build and test

macOS builds need macOS 14+, Xcode 26 / Swift 6.1+, system OpenSSH, and `librsvg` or Inkscape for icon generation. Install and accept the Xcode license before building. SwiftPM dependency downloads require network access.

Use the Makefile so the Xcode toolchain, build backend, and caches are configured consistently. `make help` lists all targets.

| Task | Command |
| --- | --- |
| Build and open isolated development app | `make run` |
| Build development / production bundle | `make app-dev` / `make app` |
| Build CLI / standalone TUI | `make cli` / `make tui` |
| Shared tests and architecture/signing gates | `make test` |
| macOS / TUI package tests | `make test-app` / `make test-tui` |
| Localization coverage | `make localization-check` |
| All package and terminal integration tests | `make test-all` |

App outputs are `.build/app-dev/ModelMoor Dev.app` and `.build/app/ModelMoor.app`, respectively. Build commands print executable paths. Development disables launch-at-login and update checks and uses separate configuration, secrets, history, runtime sockets, and ports. See the [profile paths](usage.md#configuration-and-credentials).

Terminal integration tests exercise signals, resizing, shell commands, and terminal restoration. On macOS, `test-cli-signal` needs the production runtime lock to be free; configuration overrides do not isolate that lock. Do not stop a user's active runtime merely to run tests. Use a dedicated test account or arrange a maintenance window.

## Architecture

| Module | Responsibility |
| --- | --- |
| `ModelMoorCore` | Domain types, configuration validation/migration, routing data; Foundation only |
| `ModelMoorSystem` | OpenSSH, POSIX files/locks, paths, secret storage, network and provider adapters |
| `ModelMoorGateway` | In-process SwiftNIO listener, authentication, exact routing, streaming |
| `ModelMoorApplication` | `ModelMoorSession` commands, secret-free snapshots, diagnostics and lifecycle |
| `Sources/modelmoor` | CLI commands and default TUI entry point |
| `Apps/macOS`, `Apps/TUI` | Native and terminal presentation; separate package tests |

Business mutations go through `ModelMoorSession`; presentation code subscribes to `AppSnapshot` and owns drafts, focus, and clipboard actions. Credentials are exposed only through explicit commands, not snapshots. GUI, CLI runtime, and TUI share one owner lock. Configuration writes use a separate lock and revision check to reject stale writers.

Core must not import platform, UI, or terminal frameworks. System must not import Gateway or Application; Gateway must not import Application. Keep platform shims in System. `make architecture-check` enforces these boundaries. The gateway remains an in-process library, with no separate daemon.

Schema migration preserves legacy configuration and rejects unsupported future schemas. Keep rollback, credential isolation, SSH cleanup, JSON/SSE forwarding, cancellation, and existing CLI contracts covered when changing shared code. Product scope is summarized in [positioning.md](positioning.md).

## Build resources

`Scripts/build-app.sh` assembles the executable, `Support/Info.plist`, asset catalog, localizations, privacy manifest, and license notices. `Resources/Brand/ModelMoor-AppIcon-Master.svg` is the icon source; PNG sizes are generated as needed. CLIProxyAPI is not downloaded or bundled.

Local signing is ad-hoc by default, with no certificate lookup. `MODELMOOR_CODE_SIGN_IDENTITY` explicitly selects an alternative outer-app identity. Runtime credentials do not use Keychain; certificate signing may use its private key.

Builds currently use SwiftPM's `native` backend because the default backend produces duplicate localization-resource outputs. Although deprecated in Swift 6.4, it remains required here. Bundle builds accept `MODELMOOR_BUILD_SYSTEM`. After resolving dependencies manually, run `Scripts/patch-termkit-swiftpm.sh` to exclude SwiftTerm's optional Metal shader; CI and release scripts do this already.

Edit `Apps/macOS/Sources/ModelMoor/Resources/Localizable.xcstrings`, then run `Scripts/sync-localizations.sh`. The checked-in English and Simplified Chinese `.strings` sidecars support SwiftPM runtime loading. `make localization-check` verifies parity and compiler-extracted keys. Use `Text(verbatim:)` for technical values and user data.

## Linux and releases

CI covers Ubuntu 22.04/24.04. The root package and TUI build without the macOS app. Linux uses XDG paths and explicit file-secret opt-in; network recovery relies on SSH retry rather than continuous link monitoring.

For local Linux checks, the dependency images are defined in `Scripts/Dockerfile.linux-swift` and `Scripts/Dockerfile.linux-swift-22.04`. Use the matching official Swift toolchain and a separate scratch directory for each OS/architecture. The executable CI commands in [.github/workflows](../.github/workflows) are the maintained build matrix; old test counts are not evidence for a new revision.

The release workflow builds a macOS app ZIP and Linux x86_64/aarch64 archives, publishing only after all three are available. Linux builds use the Ubuntu 22.04 ABI baseline and static Swift standard libraries; system libraries remain dynamic. `Scripts/check-linux-release-dependencies.sh` checks those dependencies. See the workflow for current signing and artifact details rather than assuming notarization or universal binaries.

Before release:

- Match the numeric Git tag, `Support/Info.plist` version/build values, and artifact names. The app's updater reads GitHub Releases; development builds disable it.
- Run package tests, localization checks, terminal contracts, and release builds for the affected platforms on the candidate revision.
- Verify upgrades preserve configuration, credentials, and history; test install/start/quit on a clean account.
- Check keyboard, VoiceOver, unsaved-edit recovery, and English/Chinese layouts for changed macOS flows.
- Keep the [README](../README.md), [site](index.html), [user guide](usage.md), and both DGX tutorials aligned with shipped behavior. Budgets are warnings, credentials are file-backed, and provider-specific subscription routes are not general protocol conversion.