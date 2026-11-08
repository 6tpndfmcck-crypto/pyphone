import XCTest
import UIKit

/// Exercises the real CPython/Pygame/SDL/UIKit stack in the simulator app.
final class PygameUITests: XCTestCase {
    func testNativeGameRendersStopsAndReopens() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let run = app.buttons["runButton"]
        XCTAssertTrue(run.waitForExistence(timeout: 30))
        waitUntilEnabled(run)
        app.tabBars.buttons["Files"].tap()
        let example = app.buttons["Pygame game"]
        XCTAssertTrue(example.waitForExistence(timeout: 10))
        example.tap()

        for attempt in 1...2 {
            waitUntilEnabled(run)
            run.tap()
            let stop = app.buttons["pygameStopButton"]
            XCTAssertTrue(stop.waitForExistence(timeout: 30), "SDL's game window did not appear")
            let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                ((try? self.greenPixels(app.screenshot().image)) ?? 0) > 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 15), .completed)
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "Native-Pygame-run-\(attempt)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(try greenPixels(screenshot.image), 100,
                                 "The SDL window is present but Pygame's green ball was not rendered")
            // Touch the real SDL view, then allow another frame to be presented.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)).tap()
            XCTAssertGreaterThan(try greenPixels(app.screenshot().image), 100)
            stop.tap()
            XCTAssertTrue(run.waitForExistence(timeout: 15), "Stop did not restore the PyPhone workspace")
            waitUntilEnabled(run)
            XCTAssertFalse(stop.exists)
        }
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND label CONTAINS 'Run'"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 60), .completed)
    }

    private func greenPixels(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = bytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: rgba.count, by: 4).reduce(0) { count, offset in
                // Allow small color-profile differences around (80, 210, 180).
                count + ((55...110).contains(Int(rgba[offset])) &&
                         (180...240).contains(Int(rgba[offset + 1])) &&
                         (145...210).contains(Int(rgba[offset + 2])) ? 1 : 0)
            }
        }
    }
}
