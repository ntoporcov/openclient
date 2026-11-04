import XCTest
import UIKit
@testable import OpenClient

@MainActor
final class DesktopStreamSurfaceTests: XCTestCase {
    func testPointerMappingAcrossFitZoomAndPanRejectsLetterboxing() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        }
        let surface = DesktopScrollSurface(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        surface.setFrame(try XCTUnwrap(image.cgImage))
        surface.layoutIfNeeded()
        // Renderer pixels reflect the device scale; mapping must use actual framebuffer pixels.
        let pixels = try XCTUnwrap(image.cgImage)
        let middle = try XCTUnwrap(surface.pointerCoordinates(at: CGPoint(x: 300, y: 300)))
        XCTAssertEqual(Int(middle.0), pixels.width / 2, accuracy: 1)
        XCTAssertEqual(Int(middle.1), pixels.height / 2, accuracy: 1)
        XCTAssertNil(surface.pointerCoordinates(at: CGPoint(x: 300, y: 20)))

        surface.zoomScale = surface.minimumZoomScale * 3
        surface.contentOffset = CGPoint(x: 200, y: 100)
        surface.layoutIfNeeded()
        let expected = CGPoint(x: CGFloat(pixels.width) * 0.4, y: CGFloat(pixels.height) * 0.6)
        let location = surface.image.convert(expected, to: surface)
        let mapped = try XCTUnwrap(surface.pointerCoordinates(at: location))
        XCTAssertEqual(Int(mapped.0), Int(expected.x), accuracy: 1)
        XCTAssertEqual(Int(mapped.1), Int(expected.y), accuracy: 1)
    }

    func testKeyboardResizePreservesZoomAndFramebufferCenter() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { _ in }.cgImage!
        let surface = DesktopScrollSurface(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        surface.setFrame(image)
        surface.layoutIfNeeded()
        let zoom = surface.minimumZoomScale * 2
        surface.zoomScale = zoom
        surface.contentOffset = CGPoint(x: 150, y: 120)
        surface.setFrame(image)
        surface.layoutIfNeeded()
        let center = surface.image.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), from: surface)
        XCTAssertEqual(surface.zoomScale, zoom, accuracy: 0.001)
        surface.frame.size = CGSize(width: 600, height: 160)
        surface.layoutIfNeeded()
        XCTAssertEqual(surface.zoomScale, zoom, accuracy: 0.001)
        var newCenter = surface.image.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), from: surface)
        XCTAssertEqual(newCenter.x, center.x, accuracy: 0.01)
        XCTAssertEqual(newCenter.y, center.y, accuracy: 0.01)
        surface.frame.size = CGSize(width: 600, height: 300)
        surface.layoutIfNeeded()
        newCenter = surface.image.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), from: surface)
        XCTAssertEqual(newCenter.x, center.x, accuracy: 0.01)
        XCTAssertEqual(newCenter.y, center.y, accuracy: 0.01)
    }

    func testClickModeKeepsTwoFingerNavigationAvailable() {
        let surface = DesktopScrollSurface()
        surface.setClickEnabled(true)
        XCTAssertTrue(surface.click.isEnabled)
        XCTAssertEqual(surface.click.numberOfTouchesRequired, 1)
        XCTAssertTrue(surface.panGestureRecognizer.isEnabled)
        XCTAssertEqual(surface.panGestureRecognizer.minimumNumberOfTouches, 2)
        XCTAssertEqual(surface.pinchGestureRecognizer?.isEnabled, true)
        surface.setClickEnabled(false)
        XCTAssertFalse(surface.click.isEnabled)
        XCTAssertEqual(surface.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertEqual(surface.pinchGestureRecognizer?.isEnabled, true)
    }
}
