import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct BrowserRootContainer<Content: View>: View {
    @ObservedObject var browser: BrowserStore
    let usesInspectorPresentation: Bool
    private let content: Content

    init(
        browser: BrowserStore,
        usesInspectorPresentation: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.browser = browser
        self.usesInspectorPresentation = usesInspectorPresentation
        self.content = content()
    }

    var body: some View {
        content
            .sheet(isPresented: Binding(
                get: {
                    browser.presentation == .expanded && !usesInspectorPresentation
                },
                set: { isPresented in
                    if !isPresented,
                       !usesInspectorPresentation,
                       browser.presentation == .expanded {
                        browser.collapse()
                    }
                }
            )) {
                BrowserSheet(browser: browser)
            }
    }
}

private struct BrowserSheet: View {
    @ObservedObject var browser: BrowserStore

    var body: some View {
        NavigationStack {
            BrowserPage(browser: browser)
                .navigationTitle(browser.displayTitle)
                .opencodeInlineNavigationTitle()
                .toolbar {
                    BrowserPresentationToolbar(
                        browser: browser,
                        collapseSystemImage: "chevron.down"
                    )
                }
        }
        .browserToolbarVisibility(true)
        .presentationDetents([.large])
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
    }
}

struct BrowserInspectorContainer<Content: View>: View {
    @ObservedObject var browser: BrowserStore
    let isEnabled: Bool
    private let content: Content
    @State private var inspectorWidth: CGFloat = 420
    @State private var inspectorHeight: CGFloat = 420
    @State private var isComposerFocused = false
    @State private var isKeyboardVisible = false
    @State private var usesVerticalLayoutWhileKeyboardIsVisible = true

    init(
        browser: BrowserStore,
        isEnabled: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.browser = browser
        self.isEnabled = isEnabled
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if isEnabled,
           browser.activeProjectID != nil,
           browser.presentation == .expanded {
            GeometryReader { proxy in
                let inferredVerticalLayout = proxy.size.height > proxy.size.width
                let usesVerticalLayout = isKeyboardVisible
                    ? usesVerticalLayoutWhileKeyboardIsVisible
                    : inferredVerticalLayout
                let maximumWidth = max(280, proxy.size.width - 220)
                let resolvedWidth = min(inspectorWidth, maximumWidth)
                let maximumHeight = max(280, proxy.size.height - 260)
                let resolvedHeight = min(inspectorHeight, maximumHeight)
                let hidesBrowser = usesVerticalLayout && isComposerFocused && isKeyboardVisible
                let visibleBrowserHeight: CGFloat = hidesBrowser ? 0 : resolvedHeight
                let contentWidth = usesVerticalLayout
                    ? proxy.size.width
                    : max(0, proxy.size.width - resolvedWidth)
                let contentHeight = usesVerticalLayout
                    ? max(0, proxy.size.height - visibleBrowserHeight)
                    : proxy.size.height

                ZStack(alignment: .topLeading) {
                    content
                        .frame(width: contentWidth, height: contentHeight)
                        .position(
                            x: usesVerticalLayout ? proxy.size.width / 2 : contentWidth / 2,
                            y: usesVerticalLayout
                                ? visibleBrowserHeight + contentHeight / 2
                                : proxy.size.height / 2
                        )

                    BrowserInspector(
                        browser: browser,
                        inspectorWidth: $inspectorWidth,
                        inspectorHeight: $inspectorHeight,
                        usesVerticalLayout: usesVerticalLayout
                    )
                    .frame(
                        width: usesVerticalLayout ? proxy.size.width : resolvedWidth,
                        height: usesVerticalLayout ? resolvedHeight : proxy.size.height
                    )
                    .position(
                        x: usesVerticalLayout
                            ? proxy.size.width / 2
                            : proxy.size.width - resolvedWidth / 2,
                        y: usesVerticalLayout
                            ? (hidesBrowser ? -resolvedHeight / 2 : resolvedHeight / 2)
                            : proxy.size.height / 2
                    )
                    .opacity(hidesBrowser ? 0 : 1)
                    .allowsHitTesting(!hidesBrowser)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: hidesBrowser)
                .onAppear {
                    usesVerticalLayoutWhileKeyboardIsVisible = inferredVerticalLayout
                }
                .onChange(of: proxy.size) { _, size in
                    guard !isKeyboardVisible else { return }
                    usesVerticalLayoutWhileKeyboardIsVisible = size.height > size.width
                }
            }
            .onPreferenceChange(ChatComposerFocusPreferenceKey.self) { isFocused in
                isComposerFocused = isFocused
            }
#if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
#endif
        } else {
            content
        }
    }
}

private struct BrowserInspector: View {
    @ObservedObject var browser: BrowserStore
    @Binding var inspectorWidth: CGFloat
    @Binding var inspectorHeight: CGFloat
    let usesVerticalLayout: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

        VStack(spacing: 0) {
            BrowserInspectorHeader(
                browser: browser,
                usesVerticalLayout: usesVerticalLayout
            )

            BrowserPage(browser: browser)
        }
        .clipShape(shape)
        .opencodeConcentricGlassSurface(
            minimumCornerRadius: 26,
            in: shape
        )
        .overlay {
            shape
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                browser.close()
            } label: {
                Image(systemName: "xmark")
            }
            .opencodeActionGlass(clear: true, size: 36, in: Circle())
            .padding(10)
            .accessibilityLabel("Close browser")
            .accessibilityIdentifier("browser.close")
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
        .padding(12)
        .overlay(alignment: .leading) {
            if !usesVerticalLayout {
                GeometryReader { proxy in
                    BrowserInspectorHorizontalResizeHandle(
                        inspectorWidth: $inspectorWidth,
                        renderedWidth: proxy.size.width
                    )
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if usesVerticalLayout {
                GeometryReader { proxy in
                    BrowserInspectorVerticalResizeHandle(
                        inspectorHeight: $inspectorHeight,
                        renderedHeight: proxy.size.height
                    )
                    .frame(height: 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
}

private struct BrowserInspectorHeader: View {
    @ObservedObject var browser: BrowserStore
    let usesVerticalLayout: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                browser.collapse()
            } label: {
                Image(systemName: usesVerticalLayout ? "chevron.up" : "chevron.forward")
            }
            .opencodeActionGlass(clear: true, size: 36, in: Circle())
            .accessibilityLabel("Collapse browser")
            .accessibilityIdentifier("browser.collapse")

            Text(browser.displayTitle)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct BrowserInspectorHorizontalResizeHandle: View {
    @Binding var inspectorWidth: CGFloat
    let renderedWidth: CGFloat
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var dragOriginWidth: CGFloat?

    private let minimumWidth: CGFloat = 320
    private let maximumWidth: CGFloat = 560

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 4, height: 48)
                    .allowsHitTesting(false)
            }
            .gesture(resizeGesture)
            .accessibilityElement()
            .accessibilityLabel("Browser")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    inspectorWidth = clamped(renderedWidth + 40)
                case .decrement:
                    inspectorWidth = clamped(renderedWidth - 40)
                @unknown default:
                    break
                }
            }
            .accessibilityIdentifier("browser.inspector.resize")
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let origin = dragOriginWidth ?? renderedWidth
                if dragOriginWidth == nil {
                    dragOriginWidth = origin
                }
                let direction: CGFloat = layoutDirection == .leftToRight ? -1 : 1
                inspectorWidth = clamped(origin + value.translation.width * direction)
            }
            .onEnded { _ in
                dragOriginWidth = nil
            }
    }

    private func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }
}

private struct BrowserInspectorVerticalResizeHandle: View {
    @Binding var inspectorHeight: CGFloat
    let renderedHeight: CGFloat
    @State private var dragOriginHeight: CGFloat?

    private let minimumHeight: CGFloat = 280
    private let maximumHeight: CGFloat = 640

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 48, height: 4)
                    .allowsHitTesting(false)
            }
            .gesture(resizeGesture)
            .accessibilityElement()
            .accessibilityLabel("Browser")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    inspectorHeight = clamped(renderedHeight + 40)
                case .decrement:
                    inspectorHeight = clamped(renderedHeight - 40)
                @unknown default:
                    break
                }
            }
            .accessibilityIdentifier("browser.inspector.resize")
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let origin = dragOriginHeight ?? renderedHeight
                if dragOriginHeight == nil {
                    dragOriginHeight = origin
                }
                inspectorHeight = clamped(origin + value.translation.height)
            }
            .onEnded { _ in
                dragOriginHeight = nil
            }
    }

    private func clamped(_ height: CGFloat) -> CGFloat {
        min(max(height, minimumHeight), maximumHeight)
    }
}

private struct BrowserPresentationToolbar: ToolbarContent {
    let browser: BrowserStore
    let collapseSystemImage: String

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .opencodeLeading) {
            Button {
                browser.collapse()
            } label: {
                Image(systemName: collapseSystemImage)
            }
            .accessibilityLabel("Collapse browser")
            .accessibilityIdentifier("browser.collapse")
        }

        ToolbarItem(placement: .opencodeTrailing) {
            Button {
                browser.close()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close browser")
            .accessibilityIdentifier("browser.close")
        }
    }
}

struct BrowserAccessoryRow: View {
    @ObservedObject var browser: BrowserStore
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            Button {
                presentBrowser()
            } label: {
                HStack(spacing: 12) {
                    BrowserFavicon(url: browser.presentation == .closed ? nil : browser.faviconURL)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(browser.presentation == .closed ? "Open browser" : "Expand browser")
            .accessibilityIdentifier(accessibilityIdentifier)

            if browser.presentation == .collapsed {
                Button {
                    browser.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close browser")
                .accessibilityIdentifier("browser.close.accessory")
            } else {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        browser.presentation == .closed ? "Browser" : browser.displayTitle
    }

    private var subtitle: String {
        browser.presentation == .closed ? "Open a webpage" : browser.displayURL
    }

    private func presentBrowser() {
        if browser.presentation == .closed {
            browser.openAddressBar()
        } else {
            browser.expand()
        }
    }
}

private struct BrowserPage: View {
    @ObservedObject var browser: BrowserStore
    @State private var isKeyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            BrowserAddressBar(browser: browser)

            if let instruction = browser.userInstruction {
                BrowserInstructionBanner(instruction: instruction) {
                    browser.dismissUserInstruction()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            ZStack {
                BrowserWebView(browser: browser)
                    .ignoresSafeArea(.container, edges: .bottom)

                if let errorMessage = browser.errorMessage, browser.currentURL == nil {
                    BrowserErrorView(message: errorMessage) {
                        browser.reloadOrStop()
                    }
                }
            }
            .overlay(alignment: .bottom) {
                BrowserMovableControls(
                    browser: browser,
                    isTemporarilyHidden: isKeyboardVisible
                )
            }
        }
        .background(OpenCodePlatformColor.secondaryGroupedBackground)
        .accessibilityElement(children: .contain)
        .animation(.snappy(duration: 0.22), value: browser.userInstruction)
        .animation(.snappy(duration: 0.22), value: browser.automationStatus)
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
#endif
    }
}

private struct BrowserInstructionBanner: View {
    let instruction: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.top, 2)

            Text(instruction)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss browser instruction")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(.tint.opacity(0.1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browser.instruction")
    }
}

private struct BrowserAutomationStatusBar: View {
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: 360)
        .frame(height: 36)
        .background(.thinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status)
        .accessibilityIdentifier("browser.automation-status")
    }
}

private enum BrowserControlsHiddenEdge {
    case leading
    case trailing
    case top
    case bottom
}

private struct BrowserMovableControls: View {
    @ObservedObject var browser: BrowserStore
    let isTemporarilyHidden: Bool
    @State private var position: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var hiddenEdge: BrowserControlsHiddenEdge?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let controlsSize = CGSize(
                width: max(1, min(360, size.width - 32)),
                height: browser.automationStatus == nil ? 54 : 98
            )

            ZStack {
                if !isTemporarilyHidden {
                    if let hiddenEdge {
                        restoreButton(edge: hiddenEdge, in: size, controlsSize: controlsSize)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        controlsCluster
                            .frame(width: controlsSize.width, height: controlsSize.height, alignment: .bottom)
                            .contentShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                            .position(resolvedPosition(in: size, controlsSize: controlsSize))
                            .simultaneousGesture(dragGesture(in: size, controlsSize: controlsSize))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.snappy(duration: 0.22), value: isTemporarilyHidden)
            .animation(.snappy(duration: 0.22), value: hiddenEdge != nil)
            .onChange(of: size) { _, newSize in
                guard let position else { return }
                self.position = constrained(position, in: newSize, controlsSize: controlsSize)
            }
        }
    }

    private var controlsCluster: some View {
        VStack(spacing: 8) {
            if let automationStatus = browser.automationStatus {
                BrowserAutomationStatusBar(status: automationStatus)
            }
            BrowserFloatingControls(browser: browser)
        }
    }

    private func dragGesture(in size: CGSize, controlsSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let origin = dragOrigin ?? resolvedPosition(in: size, controlsSize: controlsSize)
                if dragOrigin == nil { dragOrigin = origin }
                position = constrained(
                    CGPoint(
                        x: origin.x + value.translation.width,
                        y: origin.y + value.translation.height
                    ),
                    in: size,
                    controlsSize: controlsSize
                )
            }
            .onEnded { value in
                let origin = dragOrigin ?? resolvedPosition(in: size, controlsSize: controlsSize)
                let projected = CGPoint(
                    x: origin.x + value.predictedEndTranslation.width,
                    y: origin.y + value.predictedEndTranslation.height
                )
                if let edge = projectedHiddenEdge(for: projected, in: size) {
                    hiddenEdge = edge
                } else {
                    position = constrained(
                        CGPoint(
                            x: origin.x + value.translation.width,
                            y: origin.y + value.translation.height
                        ),
                        in: size,
                        controlsSize: controlsSize
                    )
                }
                dragOrigin = nil
            }
    }

    private func restoreButton(
        edge: BrowserControlsHiddenEdge,
        in size: CGSize,
        controlsSize: CGSize
    ) -> some View {
        Button {
            position = restoredPosition(from: edge, in: size, controlsSize: controlsSize)
            hiddenEdge = nil
        } label: {
            Image(systemName: restoreSymbol(for: edge))
                .font(.caption.weight(.bold))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .position(restoreButtonPosition(for: edge, in: size))
        .accessibilityLabel("Show browser controls")
        .accessibilityIdentifier("browser.controls.restore")
    }

    private func resolvedPosition(in size: CGSize, controlsSize: CGSize) -> CGPoint {
        if let position {
            return constrained(position, in: size, controlsSize: controlsSize)
        }
        return CGPoint(
            x: size.width / 2,
            y: max(controlsSize.height / 2, size.height - controlsSize.height / 2 - 14)
        )
    }

    private func constrained(_ point: CGPoint, in size: CGSize, controlsSize: CGSize) -> CGPoint {
        let horizontalInset = controlsSize.width / 2 + 8
        let verticalInset = controlsSize.height / 2 + 8
        return CGPoint(
            x: min(max(point.x, horizontalInset), max(horizontalInset, size.width - horizontalInset)),
            y: min(max(point.y, verticalInset), max(verticalInset, size.height - verticalInset))
        )
    }

    private func projectedHiddenEdge(for point: CGPoint, in size: CGSize) -> BrowserControlsHiddenEdge? {
        let overflow: [(BrowserControlsHiddenEdge, CGFloat)] = [
            (.leading, -point.x),
            (.trailing, point.x - size.width),
            (.top, -point.y),
            (.bottom, point.y - size.height),
        ]
        return overflow.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil }
    }

    private func restoredPosition(
        from edge: BrowserControlsHiddenEdge,
        in size: CGSize,
        controlsSize: CGSize
    ) -> CGPoint {
        let current = position ?? CGPoint(x: size.width / 2, y: size.height / 2)
        switch edge {
        case .leading:
            return constrained(CGPoint(x: controlsSize.width / 2 + 12, y: current.y), in: size, controlsSize: controlsSize)
        case .trailing:
            return constrained(CGPoint(x: size.width - controlsSize.width / 2 - 12, y: current.y), in: size, controlsSize: controlsSize)
        case .top:
            return constrained(CGPoint(x: current.x, y: controlsSize.height / 2 + 12), in: size, controlsSize: controlsSize)
        case .bottom:
            return constrained(CGPoint(x: current.x, y: size.height - controlsSize.height / 2 - 12), in: size, controlsSize: controlsSize)
        }
    }

    private func restoreButtonPosition(for edge: BrowserControlsHiddenEdge, in size: CGSize) -> CGPoint {
        let current = position ?? CGPoint(x: size.width / 2, y: size.height / 2)
        switch edge {
        case .leading:
            return CGPoint(x: 18, y: min(max(current.y, 24), size.height - 24))
        case .trailing:
            return CGPoint(x: size.width - 18, y: min(max(current.y, 24), size.height - 24))
        case .top:
            return CGPoint(x: min(max(current.x, 24), size.width - 24), y: 18)
        case .bottom:
            return CGPoint(x: min(max(current.x, 24), size.width - 24), y: size.height - 18)
        }
    }

    private func restoreSymbol(for edge: BrowserControlsHiddenEdge) -> String {
        switch edge {
        case .leading: return "chevron.right"
        case .trailing: return "chevron.left"
        case .top: return "chevron.down"
        case .bottom: return "chevron.up"
        }
    }
}

private struct BrowserAddressBar: View {
    @ObservedObject var browser: BrowserStore
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: browser.currentURL?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Search or enter website name", text: Binding(
                    get: { browser.addressText },
                    set: { browser.addressText = $0 }
                ))
                    .browserAddressInputTraits()
                    .submitLabel(.go)
                    .focused($isAddressFocused)
                    .onSubmit {
                        browser.submitAddress()
                        isAddressFocused = false
                    }
                    .accessibilityIdentifier("browser.address")

                Button {
                    browser.reloadOrStop()
                } label: {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(browser.isLoading ? "Stop loading" : "Reload page")
                .accessibilityIdentifier("browser.reload")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 42)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if browser.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
                    .transition(.opacity)
            } else {
                Color.clear
                    .frame(height: 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(OpenCodePlatformColor.secondaryGroupedBackground)
        .onAppear {
            focusAddressIfRequested()
        }
        .onChange(of: browser.addressFocusRequest) { _, _ in
            focusAddressIfRequested()
        }
        .onChange(of: browser.presentation) { _, presentation in
            if presentation != .expanded {
                isAddressFocused = false
            }
        }
    }

    private func focusAddressIfRequested() {
        guard browser.presentation == .expanded, browser.consumeAddressFocusRequest() else { return }
        Task { @MainActor in
            await Task.yield()
            isAddressFocused = true
        }
    }
}

private struct BrowserFloatingControls: View {
    @ObservedObject var browser: BrowserStore

    var body: some View {
        HStack(spacing: 4) {
            floatingButton(systemImage: "chevron.backward", label: "Back", isEnabled: browser.canGoBack) {
                browser.goBack()
            }

            floatingButton(systemImage: "chevron.forward", label: "Forward", isEnabled: browser.canGoForward) {
                browser.goForward()
            }

            Spacer(minLength: 18)

            if let currentURL = browser.currentURL {
                ShareLink(item: currentURL) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share page")
                .accessibilityIdentifier("browser.share")
            }

            floatingButton(
                systemImage: browser.isLoading ? "xmark" : "arrow.clockwise",
                label: browser.isLoading ? "Stop loading" : "Reload",
                isEnabled: browser.currentURL != nil || !browser.addressText.isEmpty
            ) {
                browser.reloadOrStop()
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: 360)
        .frame(height: 54)
        .opencodeConcentricGlassSurface(
            isInteractive: true,
            minimumCornerRadius: 27,
            in: Capsule()
        )
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }

    private func floatingButton(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .accessibilityLabel(label)
    }
}

private struct BrowserFavicon: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 38, height: 38)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct BrowserErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Load Page", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
        .padding(24)
        .background(OpenCodePlatformColor.secondaryGroupedBackground)
    }
}

extension View {
    func opencodeProjectBrowserAccessory(
        browser: BrowserStore,
        isEnabled: Bool = true
    ) -> some View {
        modifier(ProjectBrowserAccessoryModifier(browser: browser, isEnabled: isEnabled))
    }
}

private struct ProjectBrowserAccessoryModifier: ViewModifier {
    @ObservedObject var browser: BrowserStore
    let isEnabled: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.1, macCatalyst 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled && browser.presentation == .collapsed) {
                BrowserAccessoryRow(browser: browser, accessibilityIdentifier: "browser.projectAccessory")
            }
            .animation(.snappy(duration: 0.3, extraBounce: 0.02), value: browser.presentation)
        } else if #available(iOS 26.0, macCatalyst 26.0, *) {
            // 26.0 cannot hide the native container. Keep the TabView in place and inset only a real row.
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if isEnabled && browser.presentation == .collapsed {
                    BrowserAccessoryRow(browser: browser, accessibilityIdentifier: "browser.projectAccessory")
                        .opencodeConcentricGlassSurface(
                            isInteractive: true,
                            minimumCornerRadius: 26,
                            in: Capsule()
                        )
                        .padding(.horizontal, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.3, extraBounce: 0.02), value: browser.presentation)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private extension View {
    @ViewBuilder
    func browserToolbarVisibility(_ isVisible: Bool) -> some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        self
            .toolbar(isVisible ? Visibility.visible : Visibility.hidden, for: .navigationBar)
            .toolbar(isVisible ? Visibility.visible : Visibility.hidden, for: .bottomBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func browserAddressInputTraits() -> some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
private struct BrowserWebView: UIViewRepresentable {
    let browser: BrowserStore

    func makeUIView(context: Context) -> WKWebView {
        browser.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#elseif canImport(AppKit)
private struct BrowserWebView: NSViewRepresentable {
    let browser: BrowserStore

    func makeNSView(context: Context) -> WKWebView {
        browser.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#endif
