#if os(iOS) && canImport(UIKit) && canImport(WebKit)
import SwiftUI
import UIKit
import WebKit

struct ExcalidrawDrawingSheet: View {
    let onAttach: (OpenCodeComposerAttachment) -> Void

    @State private var exportRequestID: UUID?
    @State private var isWebViewReady = false
    @State private var isExporting = false
    @State private var currentError: ExcalidrawDrawingError?

    var body: some View {
        ZStack {
            ExcalidrawWebView(
                exportRequestID: exportRequestID,
                onReady: {
                    isWebViewReady = true
                },
                onExportedPNG: { data in
                    attachExportedDrawing(data)
                },
                onError: { error in
                    showError(error)
                }
            )
            .background(Color(uiColor: .systemBackground))

            if !isWebViewReady {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading Excalidraw")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .navigationTitle("Sketch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isExporting ? "Exporting..." : "Attach") {
                    exportDrawing()
                }
                .disabled(!isWebViewReady || isExporting)
            }
        }
        .alert(item: $currentError) { error in
            Alert(
                title: Text("Drawing Error"),
                message: Text(error.localizedDescription),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func exportDrawing() {
        guard isWebViewReady else {
            showError(.notReady)
            return
        }

        isExporting = true
        exportRequestID = UUID()
    }

    private func attachExportedDrawing(_ data: Data) {
        isExporting = false
        guard UIImage(data: data) != nil else {
            showError(.invalidPNG)
            return
        }

        let id = OpenCodeIdentifier.part()
        let attachment = OpenCodeComposerAttachment(
            id: id,
            kind: .image,
            filename: "drawing-\(id).png",
            mime: "image/png",
            dataURL: "data:image/png;base64,\(data.base64EncodedString())"
        )
        onAttach(attachment)
    }

    private func showError(_ error: ExcalidrawDrawingError) {
        isExporting = false
        currentError = error
    }
}

struct ExcalidrawWebView: UIViewRepresentable {
    let exportRequestID: UUID?
    let onReady: () -> Void
    let onExportedPNG: (Data) -> Void
    let onError: (ExcalidrawDrawingError) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "excalidraw")
        userContentController.addUserScript(Coordinator.errorReportingUserScript)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.bounces = false

        guard let indexURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "ExcalidrawWeb"
        ) else {
            DispatchQueue.main.async {
                onError(.missingBundle)
            }
            return webView
        }

        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.exportIfNeeded(exportRequestID, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "excalidraw")
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ExcalidrawWebView
        private var lastExportRequestID: UUID?
        private var hasReportedReady = false

        init(parent: ExcalidrawWebView) {
            self.parent = parent
        }

        func exportIfNeeded(_ requestID: UUID?, in webView: WKWebView) {
            guard let requestID, requestID != lastExportRequestID else { return }
            lastExportRequestID = requestID

            let script = """
            (function() {
              if (typeof window.exportExcalidrawAsPng !== 'function') {
                return 'missing-exporter';
              }
              window.exportExcalidrawAsPng();
              return 'started';
            })();
            """

            webView.evaluateJavaScript(script) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    parent.onError(.javascript(error.localizedDescription))
                    return
                }
                if let result = result as? String, result == "missing-exporter" {
                    parent.onError(.notReady)
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "excalidraw" else { return }
            guard let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else {
                parent.onError(.invalidMessage)
                return
            }

            switch type {
            case "ready":
                hasReportedReady = true
                parent.onReady()
            case "exported":
                handleExportedMessage(payload)
            case "error":
                handleErrorMessage(payload)
            default:
                parent.onError(.invalidMessage)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onError(.webView(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onError(.webView(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("typeof window.exportExcalidrawAsPng === 'function'") { [weak self] result, _ in
                guard let self else { return }
                if (result as? Bool) == true {
                    hasReportedReady = true
                    parent.onReady()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak webView] in
                guard let self, let webView, !hasReportedReady else { return }
                webView.evaluateJavaScript("typeof window.exportExcalidrawAsPng === 'function'") { [weak self] result, _ in
                    guard let self, !hasReportedReady else { return }
                    if (result as? Bool) == true {
                        hasReportedReady = true
                        parent.onReady()
                    } else {
                        parent.onError(.javascript("The drawing app loaded, but the exporter did not initialize."))
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            let allowedSchemes = ["about", "blob", "data", "file"]
            if let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        private func handleExportedMessage(_ payload: [String: Any]) {
            guard let base64 = payload["base64"] as? String, !base64.isEmpty else {
                parent.onError(.invalidBase64)
                return
            }

            let encodedPayload = base64.components(separatedBy: ",").last ?? base64
            guard let data = Data(base64Encoded: encodedPayload), !data.isEmpty else {
                parent.onError(.invalidBase64)
                return
            }

            parent.onExportedPNG(data)
        }

        private func handleErrorMessage(_ payload: [String: Any]) {
            let code = payload["code"] as? String
            let message = payload["message"] as? String

            switch code {
            case "empty-scene":
                parent.onError(.emptyScene)
            case "not-ready":
                parent.onError(.notReady)
            case "runtime-error":
                parent.onError(.javascript(message ?? "The drawing app failed to initialize."))
            default:
                parent.onError(.exportFailed(message ?? "Unable to export drawing."))
            }
        }

        static let errorReportingUserScript = WKUserScript(
            source: """
            (function() {
              if (window.__openClientExcalidrawErrorReporterInstalled) { return; }
              window.__openClientExcalidrawErrorReporterInstalled = true;
              function post(message) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.excalidraw) {
                  window.webkit.messageHandlers.excalidraw.postMessage(message);
                }
              }
              window.addEventListener('error', function(event) {
                var target = event.target;
                var message = event.message || 'The drawing app failed to initialize.';
                if (target && target !== window) {
                  message = 'Unable to load ' + (target.src || target.href || target.tagName || 'a drawing app resource') + '.';
                }
                post({ type: 'error', code: 'runtime-error', message: message });
              }, true);
              window.addEventListener('unhandledrejection', function(event) {
                post({ type: 'error', code: 'runtime-error', message: (event.reason && event.reason.message) || 'The drawing app failed to initialize.' });
              });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}

enum ExcalidrawDrawingError: LocalizedError, Identifiable {
    case emptyScene
    case exportFailed(String)
    case invalidBase64
    case invalidMessage
    case invalidPNG
    case javascript(String)
    case missingBundle
    case notReady
    case webView(String)

    var id: String {
        localizedDescription
    }

    var errorDescription: String? {
        switch self {
        case .emptyScene:
            return "Draw something before attaching."
        case let .exportFailed(message):
            return message
        case .invalidBase64:
            return "The exported drawing data could not be decoded."
        case .invalidMessage:
            return "The drawing tool returned an unexpected response."
        case .invalidPNG:
            return "The exported drawing was not a valid PNG image."
        case let .javascript(message):
            return "The drawing export script failed: \(message)"
        case .missingBundle:
            return "The bundled Excalidraw app could not be found. Rebuild the iOS app resources."
        case .notReady:
            return "Excalidraw is still loading. Try again in a moment."
        case let .webView(message):
            return "The drawing tool failed to load: \(message)"
        }
    }
}
#endif
