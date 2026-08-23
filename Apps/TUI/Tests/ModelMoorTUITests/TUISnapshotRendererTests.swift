import Foundation
import XCTest
@testable import TUIWidgets
import ModelMoorApplication
import ModelMoorCore
import ModelMoorGateway
import ModelMoorSystem

/// The non-TTY snapshot is the scriptable face of modelmoor-tui: it must stay
/// stable, complete, ASCII-clean enough for pipes, and free of secrets.
final class TUISnapshotRendererTests: XCTestCase {
    func testShellParserCoversSettingsAndConnectionCommands() {
        XCTAssertEqual(TUIShellParser.parse("add port"), .addPort)
        XCTAssertEqual(TUIShellParser.parse("add ssh"), .addSSH)
        XCTAssertEqual(TUIShellParser.parse("subs"), .subscriptions)
        XCTAssertEqual(TUIShellParser.parse("subs login codex"), .subscriptionLogin(provider: "codex"))
        XCTAssertEqual(TUIShellParser.parse("sub claude"), .subscriptionLogin(provider: "claude"))
        XCTAssertEqual(TUIShellParser.parse("subs accounts"), .subscriptionAccounts)
        XCTAssertEqual(TUIShellParser.parse("subs refresh"), .subscriptionRefresh)
        XCTAssertEqual(TUIShellParser.parse("subs cancel"), .subscriptionCancel)
        XCTAssertEqual(TUIShellParser.parse("subscriptions"), .subscriptions)
        XCTAssertEqual(TUIShellParser.parse("connect prod"), .connect(name: "prod"))
        XCTAssertEqual(TUIShellParser.parse("disconnect"), .disconnect(name: nil))
        XCTAssertEqual(TUIShellParser.parse("filter gpu local"), .filter("gpu local"))
        XCTAssertEqual(TUIShellParser.parse("clear filter"), .clearFilter)
        XCTAssertEqual(TUIShellParser.parse("clear-filter"), .clearFilter)
        XCTAssertEqual(TUIShellParser.parse("?"), .help)
    }

    func testShellParserPreservesUnknownCommandsForStatusErrors() {
        XCTAssertEqual(TUIShellParser.parse("add something"), .unknown("add something"))
        XCTAssertNil(TUIShellParser.parse("   "))
    }

    private func makeFixtureSnapshot() -> AppSnapshot {
        let tunnel = TunnelConfiguration(
            name: "lab",
            sshHost: "lab.example",
            connectOnLaunch: true
        )
        let endpoint = APIEndpointConfiguration(
            name: "lab / LLM API",
            source: .sshMapping(mappingID: tunnel.mappings[0].id, originScheme: .http)
        )
        let route = ModelRouteConfiguration(
            publicModel: "fast",
            endpointID: endpoint.id,
            upstreamModel: "upstream-fast"
        )
        var snapshot = AppSnapshot(
            configuration: ModelMoorConfiguration(
                tunnels: [tunnel],
                endpoints: [endpoint],
                routes: [route]
            ),
            isLoaded: true
        )
        snapshot.tunnelStatuses[tunnel.id] = TunnelStatus(
            tunnelID: tunnel.id,
            phase: .connected,
            message: "1 port forward active"
        )
        snapshot.usage = TokenUsageSnapshot(lastMinute: 5, lastHour: 42, lastDay: 100, last30Days: 900)
        return snapshot
    }

    func testSnapshotRendersAllSections() {
        let text = TUISnapshotRenderer.render(
            snapshot: makeFixtureSnapshot(),
            recordedOwner: nil
        )
        XCTAssertTrue(text.contains("[moorings]"))
        XCTAssertTrue(text.contains("[endpoints]"))
        XCTAssertTrue(text.contains("[routes]"))
        XCTAssertTrue(text.contains("lab\tssh:lab.example\tconnected"))
        XCTAssertTrue(text.contains("fast\t-> lab / LLM API:upstream-fast\tenabled"))
        XCTAssertTrue(text.contains("usage-24h\t100 tokens"))
    }

    func testSnapshotShowsExternalRuntimeOwner() {
        let text = TUISnapshotRenderer.render(
            snapshot: makeFixtureSnapshot(),
            recordedOwner: "pid=42 owner=ModelMoor app"
        )
        XCTAssertTrue(text.contains("owned by pid=42 owner=ModelMoor app"))
    }

    func testSnapshotHandlesEmptyConfiguration() {
        let text = TUISnapshotRenderer.render(snapshot: AppSnapshot(), recordedOwner: nil)
        XCTAssertTrue(text.contains("(none)"))
        XCTAssertTrue(text.contains("runtime\tstopped"))
    }

    func testSnapshotContainsNoEscapeSequencesOrSecrets() {
        var snapshot = makeFixtureSnapshot()
        snapshot.configuration.endpoints[0].name = "lab \u{1B}[31mAPI"
        let text = TUISnapshotRenderer.render(snapshot: snapshot, recordedOwner: nil)
        // The renderer must never emit terminal control characters itself.
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertFalse(text.contains("sk-"), "endpoint names echo user input, but no secret material may appear")
    }

    func testSnapshotReportsMissingCredentialWithoutExposingSecretMaterial() throws {
        var snapshot = makeFixtureSnapshot()
        let endpoint = APIEndpointConfiguration(
            name: "Protected",
            source: .directHTTPS(originURL: URL(string: "https://protected.example.com")!),
            authentication: .bearer
        )
        snapshot.configuration.endpoints = [endpoint]
        snapshot.availableEndpointAPIKeyIDs = []

        var text = TUISnapshotRenderer.render(snapshot: snapshot, recordedOwner: nil)
        XCTAssertTrue(text.contains("Protected\topenAICompatible\tcredential-missing"))

        snapshot.availableEndpointAPIKeyIDs = [try XCTUnwrap(endpoint.activeAPIKeyID)]
        text = TUISnapshotRenderer.render(snapshot: snapshot, recordedOwner: nil)
        XCTAssertTrue(text.contains("Protected\topenAICompatible\tunknown"))
        XCTAssertFalse(text.contains("sk-"))
    }

    func testPaneNavigationAndReadOnlyInteractionPolicyStayAligned() {
        XCTAssertEqual(TUIPane.matching(shortcut: "0"), .help)
        XCTAssertEqual(TUIPane.matching(shortcut: "1"), .overview)
        XCTAssertEqual(TUIPane.matching(shortcut: "2"), .unifiedAPI)
        XCTAssertEqual(TUIPane.matching(shortcut: "3"), .sshConnections)
        XCTAssertEqual(TUIPane.matching(shortcut: "5"), .subscriptions)
        XCTAssertEqual(TUIPane.matching(shortcut: "7"), .settings)
        XCTAssertNil(TUIPane.matching(shortcut: "x"))

        for pane in TUIPane.allCases {
            XCTAssertTrue(pane.actions.isEmpty)
            XCTAssertTrue(TUIInteractionModel.availableActions(
                for: pane,
                hasVisibleSelection: true,
                hasActiveFilter: true,
                connectionActions: TUIConnectionActionAvailability(
                    canToggleDesiredState: true,
                    canRetry: true
                ),
                endpointCanCopyURL: true
            ).isEmpty)
        }
        XCTAssertTrue(TUIInteractionModel.helpText.contains("Tab"))
        XCTAssertTrue(TUIInteractionModel.helpText.contains("mouse"))
        XCTAssertTrue(TUIInteractionModel.helpText.contains("Pane text is read-only"))
        XCTAssertTrue(TUIInteractionModel.helpText.contains("Control-Space"))
        XCTAssertTrue(TUIInteractionModel.helpText.contains("selected row"))
        XCTAssertTrue(TUIInteractionModel.helpText.contains("moor>"))
        XCTAssertTrue(TUIInteractionModel.helpText.contains("Help pane"))
        XCTAssertTrue(TUIInteractionModel.helpPageText(ascii: true).contains("Shell commands"))
        XCTAssertEqual(TUIGlyphSet.preferred().paneRange, "0-7")
        XCTAssertTrue(TUIVisibilityWorkPolicy.shouldLoadDiagnostics(selectedPane: .needsAttention))
        for pane in TUIPane.allCases where pane != .needsAttention {
            XCTAssertFalse(TUIVisibilityWorkPolicy.shouldLoadDiagnostics(selectedPane: pane))
        }
        XCTAssertTrue(TUIVisibilityWorkPolicy.shouldRefreshUsage(selectedPane: .overview))
        for pane in TUIPane.allCases where pane != .overview {
            XCTAssertFalse(TUIVisibilityWorkPolicy.shouldRefreshUsage(selectedPane: pane))
        }
        XCTAssertTrue(TUIVisibilityWorkPolicy.shouldInspectEndpoints(selectedPane: .apiEndpoints))
        for pane in TUIPane.allCases where pane != .apiEndpoints {
            XCTAssertFalse(TUIVisibilityWorkPolicy.shouldInspectEndpoints(selectedPane: pane))
        }
    }

    func testConnectionActionsFollowSelectedTunnelPhaseAndDesiredState() {
        let enabled = TunnelConfiguration(name: "GPU Lab", sshHost: "gpu.example")
        let disabled = TunnelConfiguration(
            name: "Disabled",
            sshHost: "disabled.example",
            mappings: [PortMappingConfiguration(enabled: false)],
            connectOnLaunch: false
        )

        XCTAssertEqual(
            TUIConnectionActionAvailability(
                tunnel: enabled,
                phase: .stopped,
                isRequested: false
            ),
            TUIConnectionActionAvailability(canToggleDesiredState: true, canRetry: false)
        )
        XCTAssertEqual(
            TUIConnectionActionAvailability(
                tunnel: enabled,
                phase: .failed,
                isRequested: false
            ),
            TUIConnectionActionAvailability(canToggleDesiredState: false, canRetry: true)
        )
        XCTAssertEqual(
            TUIConnectionActionAvailability(
                tunnel: enabled,
                phase: .failed,
                isRequested: true
            ),
            TUIConnectionActionAvailability(canToggleDesiredState: true, canRetry: true)
        )
        XCTAssertEqual(
            TUIConnectionActionAvailability(
                tunnel: enabled,
                phase: .disconnecting,
                isRequested: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            TUIConnectionActionAvailability(
                tunnel: disabled,
                phase: .stopped,
                isRequested: false
            ),
            .unavailable
        )
    }

    func testRefreshCoalescerBoundsWorkAndPreservesReloadIntent() {
        var coalescer = TUIRefreshCoalescer()

        XCTAssertEqual(
            coalescer.request(reloadConfiguration: false),
            .start(reloadConfiguration: false)
        )
        XCTAssertTrue(coalescer.isRefreshing)
        XCTAssertFalse(coalescer.hasQueuedRefresh)

        XCTAssertEqual(coalescer.request(reloadConfiguration: false), .queued)
        XCTAssertEqual(coalescer.request(reloadConfiguration: true), .alreadyQueued)
        XCTAssertEqual(coalescer.request(reloadConfiguration: false), .alreadyQueued)
        XCTAssertTrue(coalescer.hasQueuedRefresh)

        XCTAssertEqual(
            coalescer.completeCycle(),
            .continueRefresh(reloadConfiguration: true)
        )
        XCTAssertTrue(coalescer.isRefreshing)
        XCTAssertFalse(coalescer.hasQueuedRefresh)

        XCTAssertEqual(coalescer.completeCycle(), .finish)
        XCTAssertFalse(coalescer.isRefreshing)
        XCTAssertEqual(
            coalescer.request(reloadConfiguration: true),
            .start(reloadConfiguration: true)
        )
    }

    func testRefreshCoalescerCancellationRejectsTrailingWork() {
        var coalescer = TUIRefreshCoalescer()

        XCTAssertEqual(
            coalescer.request(reloadConfiguration: false),
            .start(reloadConfiguration: false)
        )
        XCTAssertEqual(coalescer.request(reloadConfiguration: true), .queued)
        coalescer.cancel()

        XCTAssertFalse(coalescer.isRefreshing)
        XCTAssertFalse(coalescer.hasQueuedRefresh)
        XCTAssertEqual(coalescer.completeCycle(), .finish)
        XCTAssertEqual(coalescer.request(reloadConfiguration: true), .ignored)
    }

    func testListFilterSupportsMultipleFieldsTermsAndSafeDisplay() {
        XCTAssertTrue(PresentationSearchQuery("GPU lab").matches(
            fields: ["Training GPU", "compute.lab"]
        ))
        XCTAssertTrue(PresentationSearchQuery("deepseek").matches(
            fields: ["DeepSeek", "openAICompatible"]
        ))
        XCTAssertFalse(PresentationSearchQuery("gpu cloud").matches(
            fields: ["Training GPU", "compute.lab"]
        ))
        XCTAssertEqual(PresentationSearchQuery("  gpu\u{1B}[31m  ").normalizedText, "gpu [31m")
        XCTAssertTrue(PresentationSearchQuery("   ").matches(fields: []))
    }

    func testSelectionMemoryDistinguishesFilterFallbackFromUserSelection() {
        let all = ["alpha", "beta", "gamma"]
        var selection = TUISelectionMemory(preferredID: "beta")

        // A filter hides beta and visibly falls back to gamma. Repeated
        // snapshot renders must retain beta as the preferred identity.
        XCTAssertEqual(selection.resolvedIndex(
            visibleIDs: ["alpha", "gamma"],
            allIDs: all,
            fallbackIndex: 1
        ), 1)
        XCTAssertEqual(selection.preferredID, "beta")
        XCTAssertEqual(selection.resolvedIndex(
            visibleIDs: ["alpha", "gamma"],
            allIDs: all,
            fallbackIndex: 1
        ), 1)
        XCTAssertEqual(selection.preferredID, "beta")

        // Clearing the filter restores beta by ID, even if row order changed.
        XCTAssertEqual(selection.resolvedIndex(
            visibleIDs: ["gamma", "alpha", "beta"],
            allIDs: all,
            fallbackIndex: 0
        ), 2)

        // Actual user movement while filtered intentionally replaces beta.
        selection.recordVisibleSelection(index: 0, visibleIDs: ["gamma", "alpha"])
        XCTAssertEqual(selection.preferredID, "gamma")
        XCTAssertEqual(selection.resolvedIndex(
            visibleIDs: all,
            allIDs: all,
            fallbackIndex: 1
        ), 2)
    }

    func testSelectionMemoryFallsBackOnlyWhenPreferredItemWasDeleted() {
        var selection = TUISelectionMemory(preferredID: "beta")

        XCTAssertNil(selection.resolvedIndex(
            visibleIDs: [],
            allIDs: ["alpha", "beta"],
            fallbackIndex: 0
        ))
        XCTAssertEqual(selection.preferredID, "beta")

        XCTAssertEqual(selection.resolvedIndex(
            visibleIDs: ["alpha", "gamma"],
            allIDs: ["alpha", "gamma"],
            fallbackIndex: 99
        ), 1)
        XCTAssertEqual(selection.preferredID, "gamma")
    }

    func testPreparedListFilterPerformance() {
        let documents = (0..<10_000).map { index in
            PresentationSearchDocument(fields: [
                "GPU Cluster \(index)",
                "gpu-\(index).example",
                "model-\(index)"
            ])
        }
        let query = PresentationSearchQuery("cluster 9999")

        measure {
            XCTAssertEqual(documents.lazy.filter { query.matches(document: $0) }.count, 1)
        }
    }

    func testSearchDocumentCacheRebuildsOnlyForSourceChanges() {
        var cache = TUISearchDocumentCache<[String]>()

        let first = cache.prepare(for: ["alpha", "beta"]) { source in
            source.map { PresentationSearchDocument(fields: [$0]) }
        }
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(cache.buildCount, 1)

        _ = cache.prepare(for: ["alpha", "beta"]) { _ in
            XCTFail("an identical source must reuse its prepared documents")
            return []
        }
        XCTAssertEqual(cache.buildCount, 1)

        let updated = cache.prepare(for: ["alpha", "gamma"]) { source in
            source.map { PresentationSearchDocument(fields: [$0]) }
        }
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testGlyphPreferenceAlwaysUsesASCII() {
        XCTAssertEqual(TUIGlyphSet.preferred(environment: ["MODELMOOR_TUI_ASCII": "1"]), .ascii)
        XCTAssertEqual(TUIGlyphSet.preferred(environment: ["MODELMOOR_TUI_ASCII": "0", "TERM": "dumb"]), .ascii)
        XCTAssertEqual(TUIGlyphSet.preferred(environment: ["TERM": "dumb"]), .ascii)
        XCTAssertEqual(TUIGlyphSet.preferred(environment: ["LANG": "C"]), .ascii)
        XCTAssertEqual(TUIGlyphSet.preferred(environment: ["LANG": "C.UTF-8"]), .ascii)

        let asciiSurface = [
            TUIGlyphSet.preferred().active,
            TUIGlyphSet.preferred().inactive,
            TUIGlyphSet.preferred().pending,
            TUIGlyphSet.preferred().failed,
            TUIGlyphSet.preferred().requested,
            TUIGlyphSet.preferred().info,
            TUIGlyphSet.preferred().separator,
            TUIGlyphSet.preferred().paneRange,
            TUIInteractionModel.helpText(ascii: false)
        ].joined()
        XCTAssertTrue(asciiSurface.unicodeScalars.allSatisfy(\.isASCII))
    }

    func testRenderInvalidationOnlyRebuildsAffectedPanes() {
        let initial = makeFixtureSnapshot()

        var usage = initial
        usage.usage.lastDay += 1
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: usage),
            [.overview]
        )

        var gateway = initial
        gateway.gatewayState = .running(port: 19_999)
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: gateway),
            [.summary, .overview, .gateway, .attention]
        )

        var tunnel = initial
        let tunnelID = try! XCTUnwrap(initial.configuration.tunnels.first?.id)
        tunnel.tunnelStatuses[tunnelID] = TunnelStatus(
            tunnelID: tunnelID,
            phase: .failed,
            message: "connection failed"
        )
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: tunnel),
            [.overview, .tunnels, .attention]
        )

        var inspection = initial
        let endpointID = try! XCTUnwrap(initial.configuration.endpoints.first?.id)
        inspection.inspections[endpointID] = EndpointInspection(
            endpointID: endpointID,
            url: nil,
            errorMessage: "unreachable"
        )
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: inspection),
            [.endpoints, .attention]
        )

        var credentialAvailability = initial
        credentialAvailability.availableEndpointAPIKeyIDs.insert(UUID())
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: credentialAvailability),
            [.endpoints, .attention]
        )

        var tunnelConfiguration = initial
        tunnelConfiguration.configuration.tunnels[0].name = "Renamed connection"
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: tunnelConfiguration),
            [.summary, .overview, .tunnels, .attention, .settings]
        )

        var endpointConfiguration = initial
        endpointConfiguration.configuration.endpoints[0].name = "Renamed endpoint"
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: endpointConfiguration),
            [.summary, .overview, .endpoints, .gateway, .attention, .settings]
        )

        var routeConfiguration = initial
        routeConfiguration.configuration.routes[0].publicModel = "renamed-model"
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: routeConfiguration),
            [.overview, .gateway, .settings]
        )

        var gatewayConfiguration = initial
        gatewayConfiguration.configuration.gateway.listenPort += 1
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: gatewayConfiguration),
            [.overview, .gateway, .settings]
        )

        var subscriptionConfiguration = initial
        subscriptionConfiguration.configuration.cliProxy.enabled.toggle()
        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: subscriptionConfiguration),
            [.subscriptions, .settings]
        )

        XCTAssertEqual(
            TUIRenderInvalidation.sections(previous: initial, next: initial, force: true),
            .all
        )
        XCTAssertTrue(TUIRenderInvalidation.sections(previous: initial, next: initial).isEmpty)
    }

    func testLargeSnapshotRenderingPerformance() {
        let endpoints = (0..<1_000).map { index in
            APIEndpointConfiguration(
                name: "endpoint-\(index)",
                source: .directHTTPS(originURL: URL(string: "https://api\(index).example.com")!),
                authentication: .none
            )
        }
        let routes = endpoints.enumerated().map { index, endpoint in
            ModelRouteConfiguration(
                publicModel: "public-\(index)",
                endpointID: endpoint.id,
                upstreamModel: "upstream-\(index)"
            )
        }
        let snapshot = AppSnapshot(
            configuration: ModelMoorConfiguration(endpoints: endpoints, routes: routes),
            isLoaded: true
        )

        // Exclude one-time formatter/runtime initialization so a future CI
        // baseline measures steady-state snapshot refresh work.
        let warmup = TUISnapshotRenderer.render(snapshot: snapshot, recordedOwner: nil)
        XCTAssertTrue(warmup.contains("public-999\t-> endpoint-999:upstream-999\tenabled"))

        measure {
            let text = TUISnapshotRenderer.render(snapshot: snapshot, recordedOwner: nil)
            XCTAssertTrue(text.contains("public-999\t-> endpoint-999:upstream-999\tenabled"))
        }
    }
}
