import SwiftUI

extension View {
    @ViewBuilder
    func opencodeToolbarGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func opencodeGlassSurface<S: Shape>(clear: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self
                .background(Color.clear, in: shape)
                .glassEffect(clear ? .clear : .regular, in: shape)
        } else {
            self.background(.thinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func opencodeGlassButton(clear: Bool) -> some View {
        if #available(iOS 26.1, *) {
            self.buttonStyle(.glass(clear ? .clear : .regular))
        } else {
            self.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    func opencodePrimaryGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.plain)
        }
    }
}
