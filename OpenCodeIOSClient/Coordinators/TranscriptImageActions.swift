import CoreTransferable
import Foundation
import ImageIO
import Observation
import Photos
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Original bytes are retained for sharing, copying, and saving without re-encoding.
struct TranscriptImageAsset: Sendable, Transferable {
    let data: Data
    let filename: String
    let image: OpenClientDecodedPlatformImage
    let contentType: UTType
    let colorModel: String?
    let bitDepth: Int?
    let frameCount: Int

    init?(data: Data, path: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let contentType = UTType(identifier as String),
              let image = OpenClientPlatformImageDecoder.decode(data) else { return nil }
        self.data = data
        self.filename = (path as NSString).lastPathComponent
        self.image = image
        self.contentType = contentType
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        colorModel = properties?[kCGImagePropertyColorModel] as? String
        bitDepth = (properties?[kCGImagePropertyDepth] as? NSNumber)?.intValue
        frameCount = CGImageSourceGetCount(source)
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .image) { $0.data }
            .suggestedFileName { $0.filename }
    }
}

@MainActor @Observable
final class TranscriptImageActions {
    private(set) var isSaving = false
    private(set) var isSaved = false
    private(set) var isCopied = false
    var error: String?

    func copy(_ asset: TranscriptImageAsset) {
        #if canImport(UIKit)
        UIPasteboard.general.setData(asset.data, forPasteboardType: asset.contentType.identifier)
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(asset.data, forType: .init(asset.contentType.identifier))
        #endif
        isCopied = true
    }

    func save(_ asset: TranscriptImageAsset) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            error = String(localized: "Allow access to Photos in Settings to save images.")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = asset.filename
                request.addResource(with: .photo, data: asset.data, options: options)
            }
            isSaved = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
