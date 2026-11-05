import Foundation
import Testing
import UniformTypeIdentifiers
@testable import OpenClient

struct TranscriptImageAssetTests {
    @Test func preservesOriginalBytesAndDetectsTypeInsteadOfTrustingFilename() throws {
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII="))
        let asset = try #require(TranscriptImageAsset(data: data, path: "/project/test.jpg"))
        #expect(asset.data == data)
        #expect(asset.filename == "test.jpg")
        #expect(asset.contentType == .png)
        #expect(asset.image.width == 1)
        #expect(asset.image.height == 1)
        #expect(asset.frameCount == 1)
        #expect(asset.bitDepth == 8)
    }

    @Test func rejectsInvalidImageData() {
        #expect(TranscriptImageAsset(data: Data("not an image".utf8), path: "/project/test.png") == nil)
    }
}
