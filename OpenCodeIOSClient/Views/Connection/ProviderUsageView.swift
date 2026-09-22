import SwiftUI

struct ProviderUsageView: View {
    let facade: ProviderUsageFacade
    let provider: ProviderUsageProvider
    let usesInsecureTransport: Bool
    @State private var allowsInsecureTransport = false
    @State private var accountToRemove: ProviderUsageAccount?
    @State private var isShowingRemovalConfirmation = false

    private var store: ProviderUsageStore { facade.store }

    var body: some View {
        Form {
            ProviderUsageAccountsSection(
                accounts: store.accounts.filter { $0.provider == provider }.sorted { $0.updatedAt > $1.updatedAt },
                snapshots: store.snapshots,
                statuses: store.statuses,
                onRemove: { account in
                    accountToRemove = account
                    isShowingRemovalConfirmation = true
                }
            )

            ProviderUsageDiscoverySection(
                readiness: store.candidateReadiness,
                hasContext: store.candidateContext != nil,
                candidates: store.candidates.filter { $0.provider == provider }.sorted {
                    $0.sourceLabel.localizedCaseInsensitiveCompare($1.sourceLabel) == .orderedAscending
                },
                isTracked: { facade.hasTrackedAccount(for: $0) },
                onSelect: { candidate in
                    allowsInsecureTransport = false
                    _ = facade.beginSetup(from: candidate)
                }
            )

            ProviderUsageSetupSection(
                phase: store.setupPhase,
                status: store.setupStatus,
                importError: store.setupImportError,
                usesInsecureTransport: usesInsecureTransport,
                allowsInsecureTransport: $allowsInsecureTransport,
                onApproveRead: {
                    Task { await facade.approveRead(allowsInsecureHTTP: allowsInsecureTransport) }
                },
                onCancel: {
                    allowsInsecureTransport = false
                    facade.cancel()
                }
            )
        }
        .navigationTitle(provider.title)
        .opencodeInlineNavigationTitle()
        .toolbar {
            if store.accounts.contains(where: { $0.provider == provider }) {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button {
                        Task { await facade.refreshAll(provider: provider) }
                    } label: {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task {
            await facade.appeared(provider: provider)
        }
        .onDisappear { facade.disappeared() }
        .confirmationDialog(
            "Remove Usage Account?",
            isPresented: $isShowingRemovalConfirmation,
            titleVisibility: .visible,
            presenting: accountToRemove
        ) { account in
            Button("Remove", role: .destructive) {
                Task { await facade.remove(accountID: account.id) }
                accountToRemove = nil
            }
            Button("Cancel", role: .cancel) { accountToRemove = nil }
        } message: { _ in
            Text("This removes the saved account and its credential from OpenClient.")
        }
    }

}

struct UsageLevelsNavigationSection: View {
    let facade: ProviderUsageFacade
    let usesInsecureTransport: Bool

    var body: some View {
        Section("Usage Levels") {
            NavigationLink {
                ProviderUsageDisplayConfigurationView(facade: facade)
            } label: {
                Label("Displayed Usage", systemImage: "rectangle.3.group")
            }
            .accessibilityIdentifier("configurations.usage-levels.display")

            UsageLevelsProviderLinks(facade: facade, usesInsecureTransport: usesInsecureTransport)
        }
        .task { await facade.loadPersistedAccountsOnce() }
    }
}

private struct UsageLevelsProviderLinks: View {
    let facade: ProviderUsageFacade
    let usesInsecureTransport: Bool

    var body: some View {
        ForEach(ProviderUsageProvider.allCases) { provider in
            NavigationLink {
                ProviderUsageView(
                    facade: facade,
                    provider: provider,
                    usesInsecureTransport: usesInsecureTransport
                )
            } label: {
                UsageLevelsProviderRow(
                    provider: provider,
                    accounts: facade.store.accounts.filter { $0.provider == provider },
                    statuses: facade.store.statuses
                )
            }
            .accessibilityIdentifier("configurations.usage-levels.\(provider.id)")
        }
    }
}

private struct UsageLevelsProviderRow: View {
    let provider: ProviderUsageProvider
    let accounts: [ProviderUsageAccount]
    let statuses: [UUID: ProviderUsageStatus]

    var body: some View {
        HStack(spacing: 12) {
            ProviderLogo(providerID: provider.openCodeProviderID)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.title)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: LocalizedStringResource {
        if accounts.isEmpty { return provider.description }
        if accounts.contains(where: { providerUsageStatusIsError(statuses[$0.id] ?? .savedNotChecked) }) {
            return "Needs attention"
        }
        if accounts.contains(where: { statuses[$0.id] == .refreshing }) { return "Refreshing..." }
        return accounts.count == 1 ? "1 saved account" : "Multiple saved accounts"
    }
}

private struct ProviderUsageAccountsSection: View {
    let accounts: [ProviderUsageAccount]
    let snapshots: [UUID: ProviderUsageSnapshot]
    let statuses: [UUID: ProviderUsageStatus]
    let onRemove: (ProviderUsageAccount) -> Void

    var body: some View {
        Section {
            if accounts.isEmpty {
                Text("No usage levels saved for this provider.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    ProviderUsageAccountRow(
                        account: account,
                        snapshot: snapshots[account.id],
                        status: statuses[account.id] ?? .savedNotChecked,
                        onRemove: { onRemove(account) }
                    )
                }
            }
        } header: {
            Text("Saved Usage Levels")
        } footer: {
            Text("Credentials stay in Keychain. OpenClient never displays their values.")
        }
    }
}

private struct ProviderUsageAccountRow: View {
    let account: ProviderUsageAccount
    let snapshot: ProviderUsageSnapshot?
    let status: ProviderUsageStatus
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        ProviderLogo(providerID: account.provider.openCodeProviderID)
                        Text(account.provider.title)
                            .font(.headline)
                    }
                    if let label = snapshot?.accountLabel, !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ProviderUsageStatusLabel(status: status)
            }

            if let snapshot {
                ProviderUsageSnapshotView(snapshot: snapshot)
            }

            HStack {
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
                    .tint(.red)
                    .foregroundStyle(.red)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderUsageStatusLabel: View {
    let status: ProviderUsageStatus

    var body: some View {
        HStack(spacing: 5) {
            if status == .refreshing {
                ProgressView().controlSize(.small)
            }
            Text(providerUsageStatusTitle(status))
                .foregroundStyle(providerUsageStatusIsError(status) ? Color.red : Color.secondary)
        }
        .font(.caption)
    }
}

private struct ProviderUsageSnapshotView: View {
    let snapshot: ProviderUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan = snapshot.plan, !plan.isEmpty {
                LabeledContent("Plan", value: plan)
                    .font(.subheadline)
            }

            ForEach(snapshot.metrics) { metric in
                ProviderUsageMetricRow(metric: metric)
            }

            Text("Updated \(snapshot.fetchedAt, format: .relative(presentation: .named))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProviderUsageMetricRow: View {
    let metric: ProviderUsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(metric.sourceLabel ?? String(localized: providerUsageMetricTitle(metric.kind)))
                    .font(.subheadline.weight(.medium))
                Spacer()
                if metric.isUnlimited {
                    Text("Unlimited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let percent = metric.percentUsed {
                    Text(percent / 100, format: .percent.precision(.fractionLength(0...1)))
                        .font(.caption.monospacedDigit())
                } else if let value = metric.remaining ?? metric.used ?? metric.limit {
                    ProviderUsageValueText(value: value, unit: metric.unit)
                        .font(.caption.monospacedDigit())
                }
            }

            if let percent = metric.percentUsed, !metric.isUnlimited {
                ProgressView(value: min(max(percent / 100, 0), 1))
                    .tint(percent > 100 ? .red : .accentColor)
            }

            HStack {
                if let period = metric.period {
                    Text(providerUsagePeriodTitle(period))
                }
                Spacer()
                if let resetAt = metric.resetAt {
                    Text("Resets \(resetAt, format: .relative(presentation: .named))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ProviderUsageValueText: View {
    let value: Decimal
    let unit: ProviderUsageUnit

    var body: some View {
        switch unit {
        case .currency(let code): Text(value, format: .currency(code: code))
        case .percentage: Text(Double(truncating: value as NSNumber) / 100, format: .percent)
        case .count: Text(value, format: .number)
        case .credits: Text("\(value, format: .number) credits")
        }
    }
}

private struct ProviderUsageDiscoverySection: View {
    let readiness: ProviderUsageDiscoveryReadiness
    let hasContext: Bool
    let candidates: [ProviderUsageDiscoveryCandidate]
    let isTracked: (ProviderUsageDiscoveryCandidate) -> Bool
    let onSelect: (ProviderUsageDiscoveryCandidate) -> Void

    var body: some View {
        Section {
            if readiness == .notHydrated {
                if hasContext {
                    ProgressView("Waiting for provider data...")
                } else {
                    Text("Connect to an OpenCode server to discover provider credentials.")
                        .foregroundStyle(.secondary)
                }
            } else if candidates.isEmpty {
                Text("No supported provider credentials were found on this server.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { candidate in
                    ProviderUsageCandidateRow(candidate: candidate, isTracked: isTracked(candidate)) {
                        onSelect(candidate)
                    }
                }
            }
        } header: {
            Text("Add Usage Account")
        } footer: {
            Text("OpenCode provider discovery only suggests credential sources. It does not determine which usage providers are supported.")
        }
    }
}

private struct ProviderUsageCandidateRow: View {
    let candidate: ProviderUsageDiscoveryCandidate
    let isTracked: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProviderLogo(providerID: candidate.provider.openCodeProviderID)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.provider.title)
                Text(candidate.sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .unavailable(let reason) = candidate.availability {
                    Text(providerUsageUnavailableReason(reason))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if candidate.availability.isSelectable {
                Button(action: onSelect) { Text(actionTitle) }
                    .buttonStyle(.bordered)
            } else {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var actionTitle: LocalizedStringResource {
        isTracked ? "Replace Credential" : "Set Up"
    }
}

private struct ProviderUsageSetupSection: View {
    let phase: ProviderUsageStore.SetupPhase
    let status: ProviderUsageStatus?
    let importError: ProviderUsageCredentialImportError?
    let usesInsecureTransport: Bool
    @Binding var allowsInsecureTransport: Bool
    let onApproveRead: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if phase != .idle || status != nil {
            Section("Setup") {
                switch phase {
                case .idle:
                    if let status {
                        Label(
                            providerUsageSetupStatusTitle(status, importError: importError),
                            systemImage: "exclamationmark.triangle"
                        )
                            .foregroundStyle(.red)
                        if status == .importFailed, let importError {
                            Text(providerUsageCredentialImportReason(importError))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .selected(let candidate):
                    ProviderUsageReadConsentView(
                        candidate: candidate,
                        usesInsecureTransport: usesInsecureTransport,
                        allowsInsecureTransport: $allowsInsecureTransport,
                        onApprove: onApproveRead,
                        onCancel: onCancel
                    )
                case .importing:
                    ProgressView("Reading credential...")
                    Text("OpenClient is reading only the selected provider credential. Its value will not be shown.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel, action: onCancel)
                case .reviewing, .saving:
                    ProgressView("Saving account...")
                    Button("Cancel", role: .cancel, action: onCancel)
                }
            }
        }
    }
}

private struct ProviderUsageReadConsentView: View {
    let candidate: ProviderUsageSetupCandidate
    let usesInsecureTransport: Bool
    @Binding var allowsInsecureTransport: Bool
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(providerID: candidate.provider.openCodeProviderID)
            Text(candidate.provider.title)
                .font(.headline)
        }
        Text("OpenClient needs your permission before it asks the connected OpenCode server to read this provider credential. If the read succeeds, OpenClient automatically stores the credential in Keychain and sends it only to the selected provider's usage API for this check and future refreshes. The value stays hidden.")
            .font(.footnote)
            .foregroundStyle(.secondary)

        if candidate.replacingAccountID != nil {
            Label(
                "This will replace the saved credential for this source and discard its current usage snapshot.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
        }

        if candidate.provider == .codex,
           candidate.apiProfile == .legacy,
           candidate.sourceKind == .openCodeAuth {
            Text("Automatic renewal: when this access token expires or is rejected, OpenClient may ask this connected OpenCode source to renew it and update the source authentication file. The refresh token remains on the source.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if usesInsecureTransport {
            Toggle("Allow insecure transfer for this attempt", isOn: $allowsInsecureTransport)
            Label(
                "Without HTTPS, someone controlling the network can impersonate the server and recover this credential.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
        }

        Button("Allow Credential Read", action: onApprove)
            .disabled(usesInsecureTransport && !allowsInsecureTransport)
        Button("Cancel", role: .cancel, action: onCancel)
    }
}

private func providerUsageStatusTitle(_ status: ProviderUsageStatus) -> LocalizedStringResource {
    switch status {
    case .savedNotChecked: "Saved, not checked"
    case .refreshing: "Refreshing..."
    case .ready: "Up to date"
    case .importFailed: "Credential read failed"
    case .saveFailed: "Account save failed"
    case .usageFailed(let error): providerUsageErrorTitle(error)
    case .removalFailed: "Account removal failed"
    }
}

private func providerUsageSetupStatusTitle(
    _ status: ProviderUsageStatus,
    importError: ProviderUsageCredentialImportError?
) -> LocalizedStringResource {
    guard status == .importFailed, let importError else {
        return providerUsageStatusTitle(status)
    }
    return "Credential read failed (\(importError.code))"
}

private func providerUsageCredentialImportReason(
    _ error: ProviderUsageCredentialImportError
) -> LocalizedStringResource {
    switch error {
    case .contextChanged:
        "The selected connection or workspace changed. Start setup again."
    case .insecureTransport:
        "Credential reading requires secure transport."
    case .connectionFailed, .sourceRefreshNetwork, .sourceRefreshRejected:
        "The credential helper could not connect. Check the server connection and try again."
    case .ptyCreateFailed:
        "The server could not start the credential helper."
    case .ptyCreateHTTPStatus(let status):
        "The server rejected the credential helper request (HTTP \(status))."
    case .ptyConnectFailed:
        "The credential helper started, but OpenClient could not attach to it."
    case .helperProviderInvalid, .helperSourceInvalid, .helperClientKeyInvalid, .helperPSKInvalid:
        "The server did not preserve the credential helper's required environment."
    case .timedOut:
        "The credential helper timed out. Try again."
    case .invalidReady, .invalidFrame, .authenticationFailed, .replay:
        "The credential helper's secure handshake or response was invalid. Try again."
    case .sourceMissing:
        "The selected authentication file was not found."
    case .sourceTooLarge:
        "The selected authentication file is too large to read safely."
    case .malformedSource, .sourceRefreshMalformed:
        "The selected authentication file is malformed."
    case .entryMissing:
        "The selected provider entry was not found."
    case .multipleEntries:
        "Multiple matching provider entries were found."
    case .unsupportedEntry, .unsupportedSource, .unsupportedProfile, .accountMismatch, .unsupportedRuntime:
        "The selected provider credential format is not supported."
    case .outputTooLarge, .selectedPayloadTooLarge:
        "The credential helper returned more data than allowed."
    case .cleanupFailed, .sourceRefreshWriteFailed, .sourceChanged:
        "The credential helper could not be cleaned up safely."
    }
}

private func providerUsageStatusIsError(_ status: ProviderUsageStatus) -> Bool {
    switch status {
    case .importFailed, .saveFailed, .usageFailed, .removalFailed: true
    default: false
    }
}

private func providerUsageErrorTitle(_ error: ProviderUsageError) -> LocalizedStringResource {
    switch error {
    case .credentialExpired: "Credential expired"
    case .unauthorized, .forbidden, .invalidCredential, .accountMismatch: "Credential rejected"
    case .rateLimited: "Temporarily rate limited"
    case .credentialUnavailable: "Credential unavailable"
    case .network: "Network error"
    default: "Usage unavailable"
    }
}

private func providerUsageMetricTitle(_ kind: ProviderUsageMetricKind) -> LocalizedStringResource {
    kind.displayTitle
}

private func providerUsagePeriodTitle(_ period: ProviderUsagePeriod) -> LocalizedStringResource {
    switch period {
    case .lifetime: "Lifetime"
    case .day: "Daily"
    case .week: "Weekly"
    case .month: "Monthly"
    case .rolling: "Rolling window"
    case .other: "Other period"
    }
}

private func providerUsageUnavailableReason(
    _ reason: ProviderUsageCandidateUnavailableReason
) -> LocalizedStringResource {
    switch reason {
    case .sourceExtractionUnverified: "Credential access is not verified for this source."
    case .ambiguousLegacySource: "This credential source cannot be read safely."
    case .v2CredentialKindUnknown: "Credential import is not available for this server version."
    }
}

private extension ProviderUsageProvider {
    var title: LocalizedStringResource {
        displayTitle
    }

    var description: LocalizedStringResource {
        switch self {
        case .codex: "View OpenAI usage and subscription limits."
        case .openRouter: "View OpenRouter spend, limits, and balance."
        }
    }

}
