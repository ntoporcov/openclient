import SwiftUI
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct HelpView: View {
    private let articles: [HelpArticle]

    @Namespace private var articleTransition
    @State private var selectedArticleID: String?

    init(
        articles: [HelpArticle] = HelpArticle.mockArticles,
        initiallySelectedArticleID: String? = nil
    ) {
        self.articles = articles
        _selectedArticleID = State(initialValue: initiallySelectedArticleID)
    }

    private var selectedArticle: HelpArticle? {
        articles.first { $0.id == selectedArticleID }
    }

    var body: some View {
        ZStack {
            OpenCodePlatformColor.groupedBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    helpIntro

                    LazyVStack(spacing: 24) {
                        ForEach(articles) { article in
                            Button {
                                openArticle(article)
                            } label: {
                                HelpArticleCard(
                                    article: article,
                                    namespace: articleTransition,
                                    isSourceHidden: selectedArticleID == article.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .opacity(selectedArticle == nil ? 1 : 0.22)
            .blur(radius: selectedArticle == nil ? 0 : 18)
            .allowsHitTesting(selectedArticle == nil)

            if let article = selectedArticle {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()

                HelpArticleDetail(article: article, namespace: articleTransition) {
                    closeArticle()
                }
                .zIndex(1)
            }
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(selectedArticle == nil ? Visibility.visible : Visibility.hidden, for: .navigationBar)
    }

    private var helpIntro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Featured")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text("Learn the app like a product story, not a settings manual.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)

            Text("Short guides for understanding OpenCode, connecting to your server, and using the app with confidence from the start.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func openArticle(_ article: HelpArticle) {
        withAnimation(.smooth(duration: 0.42)) {
            selectedArticleID = article.id
        }
    }

    private func closeArticle() {
        withAnimation(.smooth(duration: 0.34)) {
            selectedArticleID = nil
        }
    }
}

private struct HelpArticleCard: View {
    let article: HelpArticle
    let namespace: Namespace.ID
    let isSourceHidden: Bool

    private let titleScale: CGFloat = 0.72
    private let headlineScale: CGFloat = 0.84

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HelpArticleHero(article: article, cornerRadius: 28, height: 240)
                .matchedGeometryEffect(id: article.heroID, in: namespace)

            VStack(alignment: .leading, spacing: 12) {
                Text(article.category)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .matchedGeometryEffect(id: article.categoryID, in: namespace)

                Text(article.title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .matchedGeometryEffect(id: article.titleID, in: namespace)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(titleScale, anchor: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(article.headline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .matchedGeometryEffect(id: article.headlineID, in: namespace)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(headlineScale, anchor: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(22)
        }
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground)
                .matchedGeometryEffect(id: article.cardID, in: namespace)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
        .opacity(isSourceHidden ? 0 : 1)
    }
}

private struct HelpArticleDetail: View {
    let article: HelpArticle
    let namespace: Namespace.ID
    let onClose: () -> Void

    @State private var scrollOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    private var pullDistance: CGFloat {
        max(0, dragOffset)
    }

    private var cornerRadius: CGFloat {
        pullDistance > 0 ? min(30, 18 + (pullDistance * 0.08)) : 0
    }

    private var detailOffset: CGFloat {
        pullDistance * 0.9
    }

    private var detailScale: CGFloat {
        max(0.94, 1 - (pullDistance / 2400))
    }

    private var headerDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard scrollOffset >= -4 else {
                    dragOffset = 0
                    return
                }
                guard value.translation.height > 0 else {
                    dragOffset = 0
                    return
                }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let projectedHeight = max(value.translation.height, value.predictedEndTranslation.height)
                guard scrollOffset >= -4, projectedHeight > 0 else {
                    dragOffset = 0
                    return
                }

                if projectedHeight > 150 {
                    onClose()
                } else {
                    withAnimation(.smooth(duration: 0.26)) {
                        dragOffset = 0
                    }
                }
            }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: HelpArticleTopOffsetPreferenceKey.self,
                                    value: geometry.frame(in: .named(article.scrollSpaceName)).minY
                                )
                        }
                        .frame(height: 0)

                        VStack(alignment: .leading, spacing: 0) {
                            HelpArticleHero(article: article, cornerRadius: cornerRadius, height: 360)
                                .matchedGeometryEffect(id: article.heroID, in: namespace)

                            VStack(alignment: .leading, spacing: 26) {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(article.category)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .matchedGeometryEffect(id: article.categoryID, in: namespace)

                                    Text(article.title)
                                        .font(.system(size: 34, weight: .bold, design: .rounded))
                                        .foregroundStyle(.primary)
                                        .matchedGeometryEffect(id: article.titleID, in: namespace)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Text(article.headline)
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .matchedGeometryEffect(id: article.headlineID, in: namespace)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 24)
                            .padding(.bottom, 28)
                        }
                        .contentShape(Rectangle())
                        .simultaneousGesture(headerDismissGesture)

                        VStack(alignment: .leading, spacing: 26) {
                            Divider()

                            switch article.content {
                            case .sections(let sections):
                                ForEach(sections) { section in
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(section.title)
                                            .font(.title3.weight(.semibold))

                                        Text(section.body)
                                            .font(.body)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            case .webEmbed(let embed):
                                HelpArticleEmbeddedWebBlock(embed: embed)
                                    .padding(.horizontal, -24)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                }
                .coordinateSpace(name: article.scrollSpaceName)
                .onPreferenceChange(HelpArticleTopOffsetPreferenceKey.self) { offset in
                    scrollOffset = offset
                }
            }
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(OpenCodePlatformColor.groupedBackground)
                    .matchedGeometryEffect(id: article.cardID, in: namespace)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opencodeGlassSurface(in: Circle())
                .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
                .padding(.top, geometry.safeAreaInsets.top + 12)
                .padding(.trailing, 18)
                .zIndex(2)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .scaleEffect(detailScale, anchor: .top)
            .offset(y: detailOffset)
            .padding(.horizontal, pullDistance > 0 ? 12 : 0)
            .padding(.top, pullDistance > 0 ? 12 : 0)
            .padding(.bottom, pullDistance > 0 ? 12 : 0)
            .shadow(color: .black.opacity(pullDistance > 0 ? 0.18 : 0), radius: 28, y: 12)
            .animation(.interactiveSpring(duration: 0.32, extraBounce: 0.02), value: pullDistance)
            .ignoresSafeArea()
        }
    }
}

private struct HelpArticleHero: View {
    let article: HelpArticle
    let cornerRadius: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: article.gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.white.opacity(0.16))
                .frame(width: 220, height: 220)
                .offset(x: 120, y: -70)

            Circle()
                .fill(.white.opacity(0.10))
                .frame(width: 180, height: 180)
                .offset(x: -30, y: 40)

            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: article.symbolName)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 74, height: 74)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text(article.heroLabel)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.95))
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct HelpArticleTopOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct HelpArticle: Identifiable {
    enum Content {
        case sections([Section])
        case webEmbed(WebEmbed)
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let body: String
    }

    struct WebEmbed {
        let url: URL
        let note: String
    }

    let id: String
    let category: String
    let title: String
    let headline: String
    let heroLabel: String
    let symbolName: String
    let gradient: [Color]
    let content: Content

    var cardID: String { "help-card-\(id)" }
    var heroID: String { "help-hero-\(id)" }
    var categoryID: String { "help-category-\(id)" }
    var titleID: String { "help-title-\(id)" }
    var headlineID: String { "help-headline-\(id)" }
    var scrollSpaceName: String { "help-scroll-\(id)" }
}

extension HelpArticle {
    static let mockArticles: [HelpArticle] = [
        HelpArticle(
            id: "what-is-opencode",
            category: "Getting Started",
            title: "What Is OpenCode?",
            headline: "A quick introduction to projects, sessions, and what it feels like to work with an AI coding agent in the app.",
            heroLabel: "Meet the app before you configure it.",
            symbolName: "sparkles.rectangle.stack.fill",
            gradient: [Color(red: 0.35, green: 0.23, blue: 0.91), Color(red: 0.11, green: 0.56, blue: 0.97)],
            content: .sections([
                Section(
                    id: "overview",
                    title: "OpenCode in one sentence",
                    body: "OpenCode is a coding workspace built around an AI agent that can read context, answer questions, use tools, and help move a project forward from inside a persistent session. The iPhone client is meant to keep that same model intact while making it feel natural on a smaller, touch-first screen."
                ),
                Section(
                    id: "shape",
                    title: "How to think about the app",
                    body: "Projects are the navigation layer, sessions are ongoing threads of work inside a project, and chat is where the live collaboration happens. Instead of treating every prompt like a fresh request, the app is built around the idea that a session keeps context, tool activity, todos, and decisions together."
                ),
                Section(
                    id: "first-connect",
                    title: "What to expect after connecting",
                    body: "Once you connect to a server, the app loads your projects, discovers sessions for the selected directory, and starts listening for live events. The goal is to make the UI feel less like a remote terminal and more like a native client for the same OpenCode workflow you already know from the main app."
                )
            ])
        ),
        HelpArticle(
            id: "connect-remotely",
            category: "Remote Access",
            title: "How To Connect Remotely",
            headline: "The safest setup is usually a private network path to your OpenCode server, not a public port on the open internet.",
            heroLabel: "Pick the path that matches your risk tolerance.",
            symbolName: "network.badge.shield.half.filled",
            gradient: [Color(red: 0.07, green: 0.45, blue: 0.48), Color(red: 0.10, green: 0.72, blue: 0.63)],
            content: .sections([
                Section(
                    id: "tailscale",
                    title: "Recommended: Tailscale or another mesh VPN",
                    body: "If you want reliable remote access without exposing your server directly to the public internet, a private network layer like Tailscale is the best default. It gives your devices stable private addresses, keeps traffic encrypted, and usually makes OpenCode feel like it is still on your local network."
                ),
                Section(
                    id: "traditional-vpn",
                    title: "Traditional VPNs also work",
                    body: "A home-lab VPN, router VPN, or hosted VPN can work well too if you already trust and maintain that setup. The main goal is the same: your phone should reach the OpenCode server over a protected private path instead of an open public endpoint."
                ),
                Section(
                    id: "lan-only",
                    title: "LAN-only is the simplest option",
                    body: "If you only need OpenCode while you are at home or on the same office network, keeping the server available only on your LAN is perfectly reasonable. It is simple, low-risk, and often the least fragile option as long as you do not need access while away from that network."
                ),
                Section(
                    id: "port-forwarding",
                    title: "Port forwarding is possible, but discouraged",
                    body: "You can expose OpenCode through router port forwarding, reverse proxies, and public DNS, but that raises the security bar a lot. If you take that route, you need strong authentication, HTTPS, careful firewall rules, and confidence that you are maintaining the surface correctly. For most people, a private VPN-style path is a much better tradeoff."
                )
            ])
        ),
        HelpArticle(
            id: "bugs-and-requests",
            category: "Feedback",
            title: "Report Bugs And Request Features",
            headline: "Use the project issues page to report bugs, request features, and track the work that follows from your feedback.",
            heroLabel: "Feedback belongs in the open.",
            symbolName: "exclamationmark.bubble.fill",
            gradient: [Color(red: 0.84, green: 0.31, blue: 0.27), Color(red: 0.95, green: 0.54, blue: 0.25)],
            content: .webEmbed(
                WebEmbed(
                    url: URL(string: "https://github.com/ntoporcov/opencode-ios-client/issues")!,
                    note: "This embedded page opens this app's repository issues list so you can file bugs, request features, or follow existing reports without leaving the article flow."
                )
            )
        ),
        HelpArticle(
            id: "open-source",
            category: "Open Source",
            title: "Built In The Open",
            headline: "OpenCode and OpenClient are part of an open workflow: inspect the code, follow the discussions, and help shape what comes next.",
            heroLabel: "Use it, study it, improve it.",
            symbolName: "chevron.left.forwardslash.chevron.right",
            gradient: [Color(red: 0.18, green: 0.18, blue: 0.23), Color(red: 0.34, green: 0.36, blue: 0.45)],
            content: .sections([
                Section(
                    id: "opencode-oss",
                    title: "OpenCode is open source",
                    body: "OpenCode is not a black box product you have to trust blindly. The project is developed in the open, which means the architecture, discussions, and implementation choices can be inspected directly by the people who use it."
                ),
                Section(
                    id: "openclient-oss",
                    title: "OpenClient follows the same philosophy",
                    body: "OpenClient, this native iPhone client, is being built with the same spirit. The goal is not just to wrap the server in a mobile shell, but to create a first-class open client whose behavior, UI direction, and technical tradeoffs can all be reviewed and improved in public."
                ),
                Section(
                    id: "thanks-opencode-maintainers",
                    title: "Thanks to the OpenCode maintainers",
                    body: "OpenClient exists because the OpenCode maintainers and contributors have built the server, SDK, app patterns, and product language that this native client follows. Their work makes it possible for this app to stay aligned with the broader OpenCode ecosystem instead of becoming a separate one-off client."
                ),
                Section(
                    id: "why-it-matters",
                    title: "Why that matters",
                    body: "When the tools you use are open, you can understand how they work, verify how they handle your workflow, and contribute fixes or ideas when something falls short. That makes the app better for everyone and keeps the product direction grounded in real usage rather than guesswork."
                )
            ])
        ),
        HelpArticle(
            id: "license-notices",
            category: "Open Source",
            title: "Licenses And Notices",
            headline: "OpenClient includes open source software whose licenses require attribution in distributed builds.",
            heroLabel: "Third-party notices for bundled code.",
            symbolName: "doc.text.fill",
            gradient: [Color(red: 0.16, green: 0.25, blue: 0.34), Color(red: 0.31, green: 0.48, blue: 0.64)],
            content: .sections([
                Section(
                    id: "highlighterswift",
                    title: "HighlighterSwift",
                    body: "Copyright (c) 2026, Tony Smith. Portions copyright (c) 2016, Juan Pablo Illanes.\n\nMIT License\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."
                ),
                Section(
                    id: "highlightjs",
                    title: "Highlight.js",
                    body: "Copyright (c) 2006, Ivan Sagalaev. All rights reserved.\n\nBSD 3-Clause License\n\nRedistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:\n\n1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.\n\n2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.\n\n3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.\n\nTHIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."
                )
            ])
        )
    ]
}

private struct HelpArticleEmbeddedWebBlock: View {
    let embed: HelpArticle.WebEmbed

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(embed.note)
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            EmbeddedWebView(url: embed.url)
                .frame(minHeight: 720)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }
}

#if canImport(UIKit) && canImport(WebKit)
private struct EmbeddedWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = .clear
        webView.isOpaque = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#elseif canImport(AppKit) && canImport(WebKit)
private struct EmbeddedWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#else
private struct EmbeddedWebView: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Web embedding is unavailable on this platform.")
                .font(.body)
                .foregroundStyle(.secondary)

            Text(url.absoluteString)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
#endif
