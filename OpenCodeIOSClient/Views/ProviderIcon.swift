import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ProviderIcon: View {
    let providerID: String
    var size: CGFloat = 30

    var body: some View {
        image
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var image: Image {
        if let name = Self.assetName(for: providerID) { return Image(name) }
        return Image(systemName: "server.rack")
    }

    static func assetName(for providerID: String) -> String? {
        let brandID = ["claude-code", "claude-agent"].contains(providerID) ? "anthropic" : providerID
        return ["ProviderIcon_\(brandID)", "ProviderIcon_synthetic"].first { name in
            #if canImport(UIKit)
            UIImage(named: name) != nil
            #elseif canImport(AppKit)
            NSImage(named: NSImage.Name(name)) != nil
            #else
            false
            #endif
        }
    }
}
