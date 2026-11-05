import SwiftUI

struct TranscriptImageActionButtons: View {
    let asset: TranscriptImageAsset
    let actions: TranscriptImageActions

    var body: some View {
        Button { actions.copy(asset) } label: {
            if actions.isCopied {
                Label("Copied", systemImage: "checkmark")
            } else {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        ShareLink(item: asset, preview: SharePreview(asset.filename, image: openClientPlatformImage(asset.image.image))) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button {
            Task { await actions.save(asset) }
        } label: {
            if actions.isSaved {
                Label("Saved to Photos", systemImage: "checkmark")
            } else {
                Label("Save", systemImage: "square.and.arrow.down")
            }
        }
        .disabled(actions.isSaving || actions.isSaved)
    }
}

struct TranscriptImageActionError: ViewModifier {
    @Bindable var actions: TranscriptImageActions

    func body(content: Content) -> some View {
        content.alert("Unable to save image", isPresented: Binding(
            get: { actions.error != nil },
            set: { if !$0 { actions.error = nil } }
        )) {
            Button("OK", role: .cancel) { actions.error = nil }
        } message: {
            Text(verbatim: actions.error ?? "")
        }
    }
}

struct TranscriptImageDetailView: View {
    let asset: TranscriptImageAsset
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var actions = TranscriptImageActions()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    openClientPlatformImage(asset.image.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 480)
                        .padding(12)
                        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary, lineWidth: 1)
                        }
                        .accessibilityLabel(Text(verbatim: asset.filename))
                        .contextMenu {
                            TranscriptImageActionButtons(asset: asset, actions: actions)
                        }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            TranscriptImageActionButtons(asset: asset, actions: actions)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            TranscriptImageActionButtons(asset: asset, actions: actions)
                        }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .center)

                    TranscriptImageMetadata(asset: asset, path: path)
                }
                .padding(20)
            }
            .background(OpenCodePlatformColor.groupedBackground)
            .navigationTitle(Text(verbatim: asset.filename))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .modifier(TranscriptImageActionError(actions: actions))
    }
}

private struct TranscriptImageMetadata: View {
    let asset: TranscriptImageAsset
    let path: String

    var body: some View {
        VStack(spacing: 12) {
            LabeledContent("Name") { Text(verbatim: asset.filename) }
            LabeledContent("Type") { Text(verbatim: asset.contentType.localizedDescription ?? asset.contentType.identifier) }
            if let mime = asset.contentType.preferredMIMEType {
                LabeledContent("MIME type") { Text(verbatim: mime) }
            }
            LabeledContent("Dimensions") {
                Text("\(asset.image.width.formatted()) × \(asset.image.height.formatted()) pixels")
            }
            LabeledContent("File size") {
                Text(Int64(asset.data.count), format: .byteCount(style: .file))
            }
            if let colorModel = asset.colorModel {
                LabeledContent("Color model") { Text(verbatim: colorModel) }
            }
            if let depth = asset.bitDepth {
                LabeledContent("Bit depth") { Text(depth, format: .number) }
            }
            if asset.frameCount > 1 {
                LabeledContent("Frames") { Text(asset.frameCount, format: .number) }
            }
            LabeledContent("Path") { Text(verbatim: path) }
        }
        .font(.subheadline)
        .textSelection(.enabled)
        .padding(16)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
    }
}
