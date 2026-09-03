import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct OpenClientWhatsNewView: View {
    let release: OpenClientReleaseNotes
    @ObservedObject var connection: ConnectionFacade
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 12)

            ScrollView {
                VStack(spacing: 24) {
                    OpenClientWhatsNewHero(
                        version: release.version,
                        title: release.title,
                        summary: release.summary,
                        hero: release.hero
                    )

                    if release.hero == .ipad {
                        OpenClientWhatsNewIPadTransitionNotes(connection: connection)
                    }

                    if release.hero == .activity {
                        OpenClientWhatsNewActivityExamples()
                    }

                    if !release.internationalizationAnnouncements.isEmpty {
                        OpenClientInternationalizationAnnouncementSection(
                            announcements: release.internationalizationAnnouncements
                        )
                    }

                    if !release.features.isEmpty {
                        OpenClientWhatsNewFeatureList(
                            title: release.featureSectionTitle,
                            features: release.features
                        )
                    }
                    if release.showsSetup {
                        OpenClientWhatsNewSetupSection(connection: connection)
                    }
                }
                .frame(maxWidth: 600)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(OpenCodePlatformColor.groupedBackground)
        .safeAreaInset(edge: .bottom) {
            OpenClientWhatsNewFooter(onDone: onDone)
        }
        .presentationDetents([.fraction(0.78), .large])
        .presentationDragIndicator(.visible)
    }
}

private struct OpenClientWhatsNewActivityExamples: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SEE WHAT NEEDS YOU")
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(Self.rows) { row in
                    ActivitySessionRow(row: row, showsLastUserMessage: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity card examples")
    }

    // Keep the same precedence as the Activity screen: input, working, then idle.
    private static let rows: [ActivityFacade.RowSnapshot] = [
        makeRow(
            id: "whats-new-input",
            title: String(localized: "Ship the TestFlight build"),
            project: String(localized: "OpenClient"),
            statusTitle: String(localized: "Needs input"),
            latestUserText: String(localized: "Upload the new build to TestFlight."),
            latestAssistantText: String(localized: "Permission requested for the release command."),
            needsInput: true,
            isWorking: true,
            pendingInteractionCount: 1,
            completedTodoCount: 2,
            todoCount: 3,
            minutesAgo: 2
        ),
        makeRow(
            id: "whats-new-working",
            title: String(localized: "Polish Activity cards"),
            project: String(localized: "Design system"),
            statusTitle: String(localized: "Working"),
            latestUserText: String(localized: "Make the Activity page feel native."),
            latestAssistantText: nil,
            isWorking: true,
            runningTools: [
                ActivityFacade.ToolSnapshot(
                    id: "whats-new-tool",
                    tool: "bash",
                    title: String(localized: "Running visual checks"),
                    detail: "xcodebuild test"
                ),
            ],
            completedTodoCount: 1,
            todoCount: 3,
            minutesAgo: 5
        ),
        makeRow(
            id: "whats-new-idle",
            title: String(localized: "Review release notes"),
            project: String(localized: "OpenClient"),
            statusTitle: String(localized: "Idle"),
            latestUserText: String(localized: "Make sure the announcement is ready."),
            latestAssistantText: String(localized: "Everything is ready for your next message."),
            isLiveActivityActive: true,
            completedTodoCount: 3,
            todoCount: 3,
            minutesAgo: 15
        ),
    ]

    private static func makeRow(
        id: String,
        title: String,
        project: String,
        statusTitle: String,
        latestUserText: String,
        latestAssistantText: String?,
        needsInput: Bool = false,
        isWorking: Bool = false,
        runningTools: [ActivityFacade.ToolSnapshot] = [],
        isLiveActivityActive: Bool = false,
        pendingInteractionCount: Int = 0,
        completedTodoCount: Int,
        todoCount: Int,
        minutesAgo: Double
    ) -> ActivityFacade.RowSnapshot {
        let session = OpenCodeSession(
            id: id,
            title: title,
            workspaceID: nil,
            directory: "/examples/\(id)",
            projectID: "whats-new-\(id)",
            parentID: nil
        )
        return ActivityFacade.RowSnapshot(
            recent: RecentProjectSession(session: session, projectTitle: project, preview: nil, isBusy: isWorking),
            projectID: session.projectID ?? "whats-new",
            projectIcon: nil,
            usesGlobalProjectAvatar: false,
            needsInput: needsInput,
            isWorking: isWorking,
            statusTitle: statusTitle,
            latestUserText: latestUserText,
            latestAssistantText: latestAssistantText,
            runningTools: runningTools,
            updatedAt: Date().addingTimeInterval(-minutesAgo * 60),
            latestUserMessageAt: Date().addingTimeInterval(-minutesAgo * 60),
            pendingInteractionCount: pendingInteractionCount,
            completedTodoCount: completedTodoCount,
            todoCount: todoCount,
            isLiveActivityActive: isLiveActivityActive,
            isHydrating: false,
            hydrationGeneration: 0
        )
    }
}

private struct OpenClientWhatsNewHero: View {
    let version: String
    let title: String
    let summary: String
    let hero: OpenClientReleaseNotes.Hero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.09, blue: 0.17),
                    Color(red: 0.12, green: 0.08, blue: 0.24),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.cyan.opacity(0.28))
                .frame(width: 170, height: 170)
                .blur(radius: 4)
                .offset(x: 62, y: -70)

            Circle()
                .fill(.purple.opacity(0.3))
                .frame(width: 130, height: 130)
                .blur(radius: 12)
                .offset(x: 44, y: 124)

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(String(localized: "NEW IN \(version)"), systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.12), in: Capsule())

                    Spacer(minLength: 16)

                    switch hero {
                    case .customization:
                        OpenClientWhatsNewIconStack()
                    case .activity:
                        OpenClientWhatsNewActivityMark()
                    case .internationalization:
                        OpenClientWhatsNewLanguageMark()
                    case .ipad:
                        OpenClientWhatsNewIPadMark()
                    case .talk:
                        OpenClientWhatsNewTalkMark()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)

                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, minHeight: 225, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 24, y: 12)
        .accessibilityElement(children: .combine)
    }
}

private struct OpenClientWhatsNewTalkMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.blue.opacity(0.24))
                .frame(width: 84, height: 84)
                .blur(radius: 10)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [.blue, .cyan.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 62, height: 62)
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.48), lineWidth: 1)
                }
                .shadow(color: .blue.opacity(0.35), radius: 18, y: 8)

            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 92, height: 72)
        .accessibilityHidden(true)
    }
}

private struct OpenClientWhatsNewIPadMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.62), lineWidth: 2)
                }

            HStack(spacing: 5) {
                VStack(spacing: 4) {
                    Capsule().fill(.cyan.opacity(0.9)).frame(height: 5)
                    Capsule().fill(.white.opacity(0.45)).frame(height: 4)
                    Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                }

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.purple.opacity(0.72))
                    .overlay {
                        Image(systemName: "globe")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
            }
            .padding(9)
        }
        .frame(width: 90, height: 62)
        .accessibilityHidden(true)
    }
}

private struct OpenClientWhatsNewIPadTransitionNotes: View {
    @ObservedObject var connection: ConnectionFacade

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GOOD TO KNOW")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                Text("A couple of things moved")
                    .font(.title2.bold())
            }

            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.purple)
                            .frame(width: 46, height: 46)
                            .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fun & Games moved")
                                .font(.headline)
                            Text("Fun & Games now lives in Global Settings. It is off by default, and you can turn it on here anytime.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Toggle("Show Fun & Games", isOn: Binding(
                        get: { connection.showsFunAndGamesSection },
                        set: { connection.setShowsFunAndGamesSection($0) }
                    ))
                    .font(.subheadline.weight(.semibold))
                    .tint(.purple)
                    .accessibilityIdentifier("new-features.show-fun-and-games")
                }
                .padding(16)
                .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.purple.opacity(0.13), lineWidth: 0.5)
                }

                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 46, height: 46)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Disconnect moved")
                            .font(.headline)
                        Text("Disconnect now sits at the bottom of the Projects list, keeping the main navigation focused.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.orange.opacity(0.13), lineWidth: 0.5)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("new-features.disconnect-moved")
            }
        }
    }
}

private struct OpenClientWhatsNewActivityMark: View {
    var body: some View {
        ZStack {
            activityCard(tint: .purple, rotation: -7, offset: CGSize(width: -13, height: 6))
            activityCard(tint: .cyan, rotation: 5, offset: CGSize(width: 13, height: -5))
        }
        .frame(width: 94, height: 58)
        .accessibilityHidden(true)
    }

    private func activityCard(tint: Color, rotation: Double, offset: CGSize) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint.gradient)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(.white.opacity(0.9)).frame(width: 35, height: 5)
                Capsule().fill(.white.opacity(0.38)).frame(width: 45, height: 4)
            }
        }
        .padding(9)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.white.opacity(0.32), lineWidth: 1)
        }
        .rotationEffect(.degrees(rotation))
        .offset(offset)
    }
}

private struct OpenClientWhatsNewIconStack: View {
    var body: some View {
        HStack(spacing: -8) {
            OpenClientWhatsNewMiniIcon(systemImage: "link", tint: .cyan, rotation: -7)
            OpenClientWhatsNewMiniIcon(systemImage: "folder.fill", tint: .orange, rotation: 5)
            OpenClientWhatsNewMiniIcon(systemImage: "paintpalette.fill", tint: .purple, rotation: 9)
        }
        .accessibilityHidden(true)
    }
}

private struct OpenClientWhatsNewMiniIcon: View {
    let systemImage: String
    let tint: Color
    let rotation: Double

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.7), lineWidth: 2)
            }
            .rotationEffect(.degrees(rotation))
    }
}

private struct OpenClientWhatsNewFeatureList: View {
    let title: String
    let features: [OpenClientReleaseNotes.Feature]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEW FEATURES")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.title2.bold())
            }

            VStack(spacing: 10) {
                ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                    OpenClientWhatsNewFeatureRow(feature: feature, styleIndex: index)
                }
            }
        }
    }
}

private struct OpenClientWhatsNewFeatureRow: View {
    let feature: OpenClientReleaseNotes.Feature
    let styleIndex: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tint.opacity(0.13), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch styleIndex % 4 {
        case 0: .cyan
        case 1: .orange
        case 2: .purple
        default: .green
        }
    }
}

private struct OpenClientWhatsNewFooter: View {
    let onDone: () -> Void

    var body: some View {
        Button(action: onDone) {
            Text("Continue")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("new-features.continue")
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

private struct OpenClientWhatsNewSetupSection: View {
    @ObservedObject var connection: ConnectionFacade

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MAKE IT YOURS")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                Text("Set up your workspace")
                    .font(.title2.bold())
            }

            OpenClientWhatsNewIconPicker(connection: connection)

            Toggle(isOn: Binding(
                get: { connection.showsChatActivityShimmer },
                set: { connection.setShowsChatActivityShimmer($0) }
            )) {
                Label("Chat activity shimmer", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
            }
            .tint(.purple)
            .padding(16)
            .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            OpenClientWhatsNewAutoConnectPicker(connection: connection)
        }
    }
}

private struct OpenClientWhatsNewIconPicker: View {
    @ObservedObject var connection: ConnectionFacade

    private var store: AppIconStore { connection.appIconStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("App icon", systemImage: "app.dashed")
                .font(.headline)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(connection.appIcons) { icon in
                        OpenClientWhatsNewIconOption(
                            icon: icon,
                            isSelected: icon.alternateIconName == store.selectedAlternateIconName,
                            isDisabled: store.isChangingIcon,
                            isLocked: !connection.isAppIconEnabled(icon)
                        ) {
                            if connection.isAppIconEnabled(icon) {
                                Task { await connection.selectAppIcon(icon) }
                            } else {
                                connection.presentProLifetimePaywall()
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { store.refresh() }
    }
}

private struct OpenClientWhatsNewIconOption: View {
    let icon: OpenClientAppIcon
    let isSelected: Bool
    let isDisabled: Bool
    let isLocked: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    OpenClientWhatsNewIconArtwork(icon: icon, isSelected: isSelected, background: iconBackground)
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.7), in: Circle())
                    }
                }
                Text(icon.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isSelected)
        .accessibilityLabel(Text("Use \(icon.displayName) app icon"))
    }

    private var iconBackground: Color {
        isSelected ? .accentColor : .accentColor.opacity(0.12)
    }
}

private struct OpenClientWhatsNewIconArtwork: View {
    let icon: OpenClientAppIcon
    let isSelected: Bool
    let background: Color

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                fallback
            }
            #else
            fallback
            #endif
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fallback: some View {
        Image(systemName: icon.alternateIconName == nil ? "app.fill" : "paintpalette.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
    }

    #if canImport(UIKit)
    private var image: UIImage? {
        for file in icon.iconFiles.reversed() {
            if let path = Bundle.main.path(forResource: file, ofType: nil),
               let image = UIImage(contentsOfFile: path) {
                return image
            }
            if let image = UIImage(named: file) {
                return image
            }
        }
        return nil
    }
    #endif
}

private struct OpenClientWhatsNewAutoConnectPicker: View {
    @ObservedObject var connection: ConnectionFacade

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect on launch", systemImage: "bolt.horizontal.circle.fill")
                .font(.headline)

            if connection.recentServerConfigs.isEmpty {
                Text("Add a server first, then choose it here to connect automatically when OpenClient opens.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Auto-Connect Server", selection: Binding(
                    get: { connection.autoConnectServerID },
                    set: { connection.setAutoConnectServerID($0) }
                )) {
                    Text("Off").tag(nil as String?)
                    ForEach(connection.recentServerConfigs, id: \.recentServerID) { server in
                        Text(server.displayName).tag(server.recentServerID as String?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                if connection.autoConnectServerID != nil {
                    Picker("Open After Auto-Connect", selection: Binding(
                        get: { connection.autoConnectLandingDestination },
                        set: { connection.setAutoConnectLandingDestination($0) }
                    )) {
                        ForEach(AutoConnectLandingDestination.allCases) { destination in
                            Text(destination.title).tag(destination)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("new-features.auto-connect-landing-destination")
                }
            }
        }
        .padding(16)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

enum OpenClientVisualMediaDemo {
    static let imageData: Data = {
        guard let url = Bundle.main.url(
            forResource: "homepage-preview",
            withExtension: "jpg",
            subdirectory: "WhatsNew"
        ), let data = try? Data(contentsOf: url) else {
            preconditionFailure("Missing full-resolution visual media fixture")
        }
        return data
    }()

    static let loadedImage: OpenClientLoadedImage = {
        guard let decoded = OpenClientPlatformImageDecoder.decode(imageData),
              decoded.width == 960, decoded.height == 540 else {
            preconditionFailure("Invalid full-resolution visual media fixture")
        }
        return OpenClientLoadedImage(
            data: imageData,
            platformImage: decoded.image,
            width: decoded.width,
            height: decoded.height
        )
    }()

    static let preview: OpenClientVisualPreview = {
        guard let url = Bundle.main.url(
            forResource: "visual-media-preview",
            withExtension: "jpg",
            subdirectory: "WhatsNew"
        ), let data = try? Data(contentsOf: url) else {
            preconditionFailure("Missing visual media preview fixture")
        }
        do {
            return try OpenClientVisualPreview(jpegData: data, width: 96, height: 54)
        } catch {
            preconditionFailure("Invalid visual media preview fixture: \(error)")
        }
    }()

    static let imageActivity = OpenClientVisualImageActivity(
        payload: OpenClientVisualImagePayload(
            schemaVersion: OpenClientVisualImageContract.schemaVersion,
            title: "Updated homepage",
            accessibilityLabel: "A responsive OpenClient homepage preview.",
            resourceID: "screenshot_image_resource_000001",
            contentPath: "/openclient/v1/image/resources/screenshot_image_resource_000001/content",
            expiresAt: "2100-01-01T00:00:00.000Z",
            width: 960,
            height: 540,
            file: OpenClientVisualImageFile(
                name: "homepage-preview.jpg",
                sizeBytes: Int64(imageData.count),
                modifiedAt: "2026-07-28T00:00:00.000Z",
                mimeType: "image/jpeg"
            ),
            preview: preview
        )
    )

    static let videoPayload = OpenClientVisualVideoPayload(
        schemaVersion: OpenClientVisualVideoContract.schemaVersion,
        title: "Website update preview",
        resourceID: "screenshot_video_resource_000001",
        startPath: "/openclient/v1/video/resources/screenshot_video_resource_000001/stream",
        stopPath: "/openclient/v1/video/resources/screenshot_video_resource_000001/stream",
        expiresAt: "2100-01-01T00:00:00.000Z",
        file: OpenClientVisualVideoFile(
            name: "homepage-preview.mp4",
            sizeBytes: 35_000,
            modifiedAt: "2026-07-28T00:00:00.000Z",
            mimeType: "video/mp4"
        ),
        width: 960,
        height: 540,
        rotation: 0,
        duration: 6,
        cover: preview
    )
}
