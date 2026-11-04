import SwiftUI
import WebKit

private struct DesktopBridgeKey: EnvironmentKey {
    static let defaultValue: OpenClientBridgeFacade? = nil
}

extension EnvironmentValues {
    var desktopBridge: OpenClientBridgeFacade? {
        get { self[DesktopBridgeKey.self] }
        set { self[DesktopBridgeKey.self] = newValue }
    }
}

struct OpenClientRemoteDesktopButton: View {
    @ObservedObject var bridge: OpenClientBridgeFacade
    var handoff: OpenClientDesktopHandoff? = nil
    @State private var isPresented = false

    var body: some View {
        if let endpoint = bridge.remoteDesktopEndpoint {
            Button { isPresented = true } label: {
                Label("Remote Desktop", systemImage: "desktopcomputer")
            }
            .accessibilityIdentifier("remote-desktop.open")
            .sheet(isPresented: $isPresented) {
                OpenClientRemoteDesktopView(endpoint: endpoint, handoff: handoff)
            }
            .onChange(of: bridge.remoteDesktopEndpoint) { _, value in
                if value != endpoint { isPresented = false }
            }
        }
    }
}

struct OpenClientDesktopHandoffCard: View {
    @Environment(\.desktopBridge) private var bridge
    let handoff: OpenClientDesktopHandoff
    let pending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your help is needed", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
            Text(verbatim: handoff.reason)
            if pending {
                if let bridge {
                    OpenClientRemoteDesktopButton(bridge: bridge, handoff: handoff)
                } else {
                    Text("Connect the OpenClient plugin to open the desktop.").font(.caption)
                }
            } else {
                Text(handoff.outcome == "done" ? "Completed" : "Closed")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("chat.remote-desktop.handoff")
    }
}

private struct OpenClientRemoteDesktopView: View {
    let endpoint: OpenClientBridgeEndpoint
    let handoff: OpenClientDesktopHandoff?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = OpenClientRemoteDesktopStore()
    @State private var coordinator = OpenClientRemoteDesktopCoordinator()
    @State private var token = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let handoff {
                    Text(verbatim: handoff.reason).font(.callout).padding()
                }
                if let error = store.errorMessage {
                    Text(verbatim: error).foregroundStyle(.red).padding()
                }
                if let url = store.viewerURL {
                    DesktopWebView(url: url).id(url)
                } else {
                    Form {
                        Section {
                            SecureField("Remote access token", text: $token)
                                .autocorrectionDisabled()
                            Button("Connect") { coordinator.open(endpoint: endpoint, token: token, store: store) }
                                .disabled(token.isEmpty || store.isBusy)
                        } footer: {
                            Text("Enter the OPENCLIENT_REMOTE_DESKTOP_TOKEN configured on your host. Desktop login happens inside the viewer.")
                        }
                        if store.isBusy { ProgressView() }
                    }
                }
                if let handoff {
                    DesktopHandoffActions(isBusy: store.isBusy || token.isEmpty) { outcome in
                        coordinator.complete(handoff, outcome: outcome, endpoint: endpoint, token: token, store: store)
                    }
                }
            }
            .navigationTitle("Remote Desktop")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reconnect") { coordinator.open(endpoint: endpoint, token: token, store: store) }
                        .disabled(token.isEmpty || store.isBusy)
                }
            }
        }
        .onChange(of: store.completed) { _, completed in if completed { dismiss() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { coordinator.disconnect(store: store) }
        }
        .onDisappear { coordinator.disconnect(store: store) }
    }
}

private struct DesktopHandoffActions: View {
    let isBusy: Bool
    let complete: (String) -> Void
    var body: some View {
        HStack {
            Button("Cancel request", role: .destructive) { complete("cancelled") }
            Spacer()
            Button("Done — continue") { complete("done") }.buttonStyle(.borderedProminent)
        }
        .padding().disabled(isBusy)
    }
}

@MainActor
private final class DesktopWebNavigation: NSObject, WKNavigationDelegate {
    let url: URL
    init(url: URL) { self.url = url }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let target = action.request.url
        return target?.scheme == url.scheme && target?.host == url.host
            && target?.port == url.port && target?.path == url.path ? .allow : .cancel
    }
}

#if canImport(UIKit)
private struct DesktopWebView: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> DesktopWebNavigation { DesktopWebNavigation(url: url) }
    func makeUIView(context: Context) -> WKWebView { makeDesktopWebView(url: url, delegate: context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: DesktopWebNavigation) {
        view.navigationDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }
}
#else
private struct DesktopWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> DesktopWebNavigation { DesktopWebNavigation(url: url) }
    func makeNSView(context: Context) -> WKWebView { makeDesktopWebView(url: url, delegate: context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: DesktopWebNavigation) {
        view.navigationDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }
}
#endif

@MainActor
private func makeDesktopWebView(url: URL, delegate: DesktopWebNavigation) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = delegate
    view.load(URLRequest(url: url))
    return view
}
