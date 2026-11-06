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
        XCTAssertEqual(surface.click.numberOfTapsRequired, 1)
        XCTAssertTrue(surface.pointerDrag.isEnabled)
        XCTAssertTrue(surface.gestureRecognizer(surface.pointerDrag,
                                               shouldRecognizeSimultaneouslyWith: surface.panGestureRecognizer))
        XCTAssertEqual(surface.click.numberOfTouchesRequired, 1)
        XCTAssertTrue(surface.panGestureRecognizer.isEnabled)
        XCTAssertEqual(surface.panGestureRecognizer.minimumNumberOfTouches, 2)
        XCTAssertEqual(surface.pinchGestureRecognizer?.isEnabled, true)
        surface.setClickEnabled(false)
        XCTAssertFalse(surface.click.isEnabled)
        XCTAssertFalse(surface.pointerDrag.isEnabled)
        XCTAssertEqual(surface.panGestureRecognizer.minimumNumberOfTouches, 1)
        XCTAssertEqual(surface.pinchGestureRecognizer?.isEnabled, true)
    }
    func testHoldDragClampsToDesktopAndReleasesWhenNavigationTakesOver() throws {
        let pixels = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
            .image { _ in }.cgImage)
        let surface = DesktopScrollSurface(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let pointer = RecordingDesktopPointer()
        surface.pointerInput = pointer
        surface.setFrame(pixels)
        surface.setClickEnabled(true)
        surface.layoutSubviews()
        XCTAssertFalse(surface.beginPointerDrag(at: CGPoint(x: 300, y: 10)))
        XCTAssertTrue(pointer.events.isEmpty, "Letterboxing must not begin a remote drag")
        XCTAssertTrue(surface.beginPointerDrag(at: CGPoint(x: 300, y: 300)))
        surface.continuePointerDrag(at: CGPoint(x: 900, y: 900))
        XCTAssertEqual(pointer.events.last?.x, UInt16(pixels.width - 1))
        XCTAssertEqual(pointer.events.last?.y, UInt16(pixels.height - 1))
        surface.scrollViewWillBeginDragging(surface)
        XCTAssertEqual(pointer.events.last?.down, false)
        let count = pointer.events.count
        surface.continuePointerDrag(at: CGPoint(x: 300, y: 300))
        surface.endPointerDrag()
        XCTAssertEqual(pointer.events.count, count, "Cancelled gestures cannot re-press the remote mouse")
    }

    func testModeChangeResizeAndTeardownReleaseRemoteMouseExactlyOnce() throws {
        let pixels = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
            .image { _ in }.cgImage)
        let surface = DesktopScrollSurface(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let pointer = RecordingDesktopPointer()
        surface.pointerInput = pointer
        surface.setFrame(pixels)
        surface.setClickEnabled(true)
        surface.layoutSubviews()
        XCTAssertTrue(surface.beginPointerDrag(at: CGPoint(x: 300, y: 150)))
        surface.setClickEnabled(false)
        XCTAssertEqual(pointer.events.map(\.down), [true, false])
        XCTAssertFalse(surface.beginPointerDrag(at: CGPoint(x: 300, y: 150)))
        surface.setClickEnabled(true)
        XCTAssertTrue(surface.beginPointerDrag(at: CGPoint(x: 300, y: 150)))
        surface.frame.size.height = 200
        surface.layoutSubviews()
        XCTAssertEqual(pointer.events.map(\.down), [true, false, true, false])
        XCTAssertTrue(surface.beginPointerDrag(at: CGPoint(x: 300, y: 100)))
        DesktopStreamSurface.dismantleUIView(surface, coordinator: ())
        XCTAssertEqual(pointer.events.map(\.down), [true, false, true, false, true, false])
    }

    func testStationaryHoldPreservesSelectionAndCancelledHoldDoesNothing() throws {
        let pixels = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
            .image { _ in }.cgImage)
        let surface = DesktopScrollSurface(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let pointer = RecordingDesktopPointer()
        surface.pointerInput = pointer
        surface.setFrame(pixels)
        surface.setClickEnabled(true)
        surface.layoutSubviews()
        let center = CGPoint(x: 300, y: 150)
        XCTAssertTrue(surface.beginPointerHold(at: center))
        surface.updatePointerHold(at: CGPoint(x: 303, y: 151))
        XCTAssertTrue(pointer.events.isEmpty)
        surface.finishPointerHold(at: center)
        XCTAssertTrue(pointer.events.isEmpty, "Right-click must not first send a selection-clearing left click")
        XCTAssertEqual(pointer.secondaryClicks, 1)
        XCTAssertTrue(surface.beginPointerHold(at: center))
        surface.scrollViewWillBeginZooming(surface, with: surface.image)
        surface.finishPointerHold(at: center)
        XCTAssertEqual(pointer.secondaryClicks, 1)
        XCTAssertTrue(pointer.events.isEmpty)
    }

    func testRemoteSwipeScrollsNaturallyAndNavigationCancelsRemainderAndFeedback() throws {
        let pixels = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { _ in }.cgImage)
        let surface = DesktopScrollSurface(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let pointer = RecordingDesktopPointer()
        surface.pointerInput = pointer
        surface.setFrame(pixels)
        surface.setClickEnabled(true)
        surface.layoutSubviews()
        XCTAssertFalse(surface.beginRemoteScroll(at: CGPoint(x: 300, y: 10)))
        let center = CGPoint(x: 300, y: 300)
        XCTAssertTrue(surface.beginRemoteScroll(at: center))
        surface.feedback.begin(at: center)
        surface.updateRemoteScroll(by: CGPoint(x: 0, y: -4))
        XCTAssertTrue(pointer.scrolls.isEmpty)
        surface.updateRemoteScroll(by: CGPoint(x: -8, y: -4))
        XCTAssertEqual(pointer.scrolls.last?.horizontal, 1)
        XCTAssertEqual(pointer.scrolls.last?.vertical, 1)
        XCTAssertTrue(pointer.events.isEmpty, "Scrolling must not press the left mouse button")
        surface.updateRemoteScroll(by: CGPoint(x: 0, y: 8))
        XCTAssertEqual(pointer.scrolls.last?.vertical, -1)
        surface.scrollViewWillBeginZooming(surface, with: surface.image)
        XCTAssertFalse(surface.feedback.isActive)
        surface.updateRemoteScroll(by: CGPoint(x: 0, y: -48))
        XCTAssertEqual(pointer.scrolls.count, 2)
        XCTAssertTrue(surface.beginPointerHold(at: center))
        XCTAssertFalse(surface.beginRemoteScroll(at: center), "A hold selects or right-clicks, never scrolls")
        surface.finishPointerHold(at: center)
        surface.setClickEnabled(false)
        XCTAssertFalse(surface.beginRemoteScroll(at: center))
    }
}

@MainActor
private final class RecordingDesktopPointer: DesktopPointerInput {
    struct Event { let x: UInt16; let y: UInt16; let down: Bool }
    var events: [Event] = []
    var secondaryClicks = 0
    struct Scroll { let horizontal: Int; let vertical: Int }
    var scrolls: [Scroll] = []
    func pointer(x: UInt16, y: UInt16, down: Bool) { events.append(Event(x: x, y: y, down: down)) }
    func secondaryClick(x: UInt16, y: UInt16) { secondaryClicks += 1 }
    func scroll(x: UInt16, y: UInt16, horizontal: Int, vertical: Int) {
        scrolls.append(Scroll(horizontal: horizontal, vertical: vertical))
    }
}
