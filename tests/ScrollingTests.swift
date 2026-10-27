import XCTest
import SwiftUI
import UIKit

final class ScrollingTests: XCTestCase {
    @MainActor
    private func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let view = root as? T { return view }
        for child in root.subviews {
            if let result = find(type, in: child) { return result }
        }
        return nil
    }

    @MainActor
    private func imageWidget(id: Int = 7, revision: Int, size: CGSize) throws -> Widget {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return Widget(id: id, kind: "image", text: "test image", placeholder: "",
                      image_data: try XCTUnwrap(image.pngData()).base64EncodedString(), image_revision: revision)
    }

    @MainActor
    private func attachment(in terminal: TerminalTextView, at location: Int) -> NSTextAttachment? {
        guard terminal.textStorage.length > location else { return nil }
        return terminal.textStorage.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment
    }

    @MainActor
    private func waitForImage(in terminal: TerminalTextView, at location: Int, size: CGSize) async throws -> NSTextAttachment {
        for _ in 0..<200 {
            terminal.layoutIfNeeded()
            if let attachment = attachment(in: terminal, at: location), attachment.image?.size == size {
                return attachment
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let result = try XCTUnwrap(attachment(in: terminal, at: location))
        XCTAssertEqual(result.image?.size, size, "The latest image frame was not displayed")
        return result
    }

    @MainActor
    func testEditorCanReachLastLineAfterLayoutAndResize() async throws {
        let code = (1...150).map { "print('Line \($0): a deliberately long line to wrap on an iPhone display')" }.joined(separator: "\n")
        let host = UIHostingController(rootView: GeometryReader { viewport in
            CodeEditor(text: .constant(code))
                .frame(width: viewport.size.width, height: viewport.size.height)
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let editor = try XCTUnwrap(find(EditorTextView.self, in: host.view))
        editor.layoutManager.ensureLayout(for: editor.textContainer)
        editor.layoutIfNeeded()
        XCTAssertTrue(editor.isScrollEnabled)
        XCTAssertGreaterThan(editor.bounds.height, 0)
        XCTAssertLessThanOrEqual(editor.bounds.height, 600)
        XCTAssertGreaterThan(editor.contentSize.height, editor.bounds.height * 2)
        XCTAssertEqual(editor.gutter.lineStarts.count, 150)

        editor.setContentOffset(CGPoint(x: 0, y: editor.contentSize.height - editor.bounds.height), animated: false)
        editor.setNeedsLayout()
        editor.layoutIfNeeded()
        // Rendering the line-number overlay must not reset scrolling.
        UIGraphicsImageRenderer(size: editor.gutter.bounds.size).image { context in
            editor.gutter.layer.render(in: context.cgContext)
        }
        XCTAssertGreaterThan(editor.contentOffset.y, 0)
        XCTAssertEqual(editor.gutter.frame.minY, editor.contentOffset.y, accuracy: 1)
        XCTAssertEqual(editor.contentOffset.y + editor.bounds.height, editor.contentSize.height, accuracy: 2)

        window.frame.size = CGSize(width: 600, height: 320)
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        editor.layoutManager.ensureLayout(for: editor.textContainer)
        editor.layoutIfNeeded()
        editor.setContentOffset(CGPoint(x: 0, y: editor.contentSize.height - editor.bounds.height), animated: false)
        editor.layoutIfNeeded()
        XCTAssertGreaterThan(editor.contentOffset.y, 0)
        XCTAssertEqual(editor.contentOffset.y + editor.bounds.height, editor.contentSize.height, accuracy: 2)
    }

    @MainActor
    func testTerminalFollowsOutputButPreservesScrollback() async throws {
        let host = UIHostingController(rootView: TerminalView(output: ""))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let terminal = try XCTUnwrap(find(TerminalTextView.self, in: host.view))
        let output = (1...100).map { "output \($0)\n" }.joined()
        terminal.setOutput(output, images: [], imageRevision: 0)
        terminal.layoutIfNeeded()
        XCTAssertGreaterThan(terminal.bottomOffset, 0)
        XCTAssertEqual(terminal.contentOffset.y, terminal.bottomOffset, accuracy: 2)

        terminal.setOutput(output + "new output\n", images: [], imageRevision: 0)
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, terminal.bottomOffset, accuracy: 2)

        // Model a user drag away from the bottom, then append more output.
        terminal.pauseFollowing()
        terminal.setContentOffset(CGPoint(x: 0, y: 80), animated: false)
        terminal.updateFollowPosition()
        XCTAssertFalse(terminal.followsOutput)
        terminal.setOutput(output + "new output\nmore output\n", images: [], imageRevision: 0)
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, 80, accuracy: 2)

        terminal.scrollToBottom()
        terminal.updateFollowPosition()
        XCTAssertTrue(terminal.followsOutput)
        terminal.setOutput(output + "last line\n", images: [], imageRevision: 0)
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, terminal.bottomOffset, accuracy: 2)

        terminal.pauseFollowing()
        terminal.setOutput("", images: [], imageRevision: 0)
        XCTAssertTrue(terminal.followsOutput)
        terminal.setOutput(output, images: [], imageRevision: 0)
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, terminal.bottomOffset, accuracy: 2)
    }

    @MainActor
    func testTerminalUpdatesInlineImagesThroughSwiftUI() async throws {
        let host = UIHostingController(rootView: TerminalView(output: "before\n"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let terminal = try XCTUnwrap(find(TerminalTextView.self, in: host.view))
        let output = "before\n\u{001F}PYPHONE_IMAGE:7\u{001E}\nafter\n"

        for revision in 1...2 {
            let size = CGSize(width: CGFloat(revision * 10), height: 10)
            host.rootView = TerminalView(output: output, images: [try imageWidget(revision: revision, size: size)], imageRevision: revision)
            host.view.setNeedsLayout()
            let updated = try await waitForImage(in: terminal, at: 7, size: size)
            host.view.layoutIfNeeded()
            // Reuse the native view to exercise updateUIView, including an
            // image revision change with unchanged console text.
            XCTAssertTrue(terminal === find(TerminalTextView.self, in: host.view))
            XCTAssertEqual(terminal.attributedText.string, "before\n\u{FFFC}\nafter\n")
            XCTAssertEqual(try XCTUnwrap(updated.image).size, size)
        }
    }

    @MainActor
    func testAnimationKeepsImageSlotsTextAndScrollback() async throws {
        let terminal = TerminalTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), textContainer: nil)
        terminal.isSelectable = true
        let prefix = (1...100).map { "output \($0)\n" }.joined()
        let firstPosition = (prefix as NSString).length
        let secondPosition = firstPosition + 2
        let output = prefix + "\u{001F}PYPHONE_IMAGE:7\u{001E}\n\u{001F}PYPHONE_IMAGE:8\u{001E}\nafter\n"
        let staticImage = try imageWidget(id: 8, revision: 1, size: CGSize(width: 10, height: 10))
        terminal.setOutput(output, images: [try imageWidget(revision: 1, size: CGSize(width: 20, height: 10)), staticImage], imageRevision: 1)
        let moving = try await waitForImage(in: terminal, at: firstPosition, size: CGSize(width: 20, height: 10))
        let fixed = try await waitForImage(in: terminal, at: secondPosition, size: CGSize(width: 10, height: 10))
        let fixedPixels = try XCTUnwrap(fixed.image)
        let text = terminal.attributedText.string
        terminal.pauseFollowing()
        terminal.selectedRange = NSRange(location: 0, length: 6)
        terminal.setContentOffset(CGPoint(x: 0, y: 80), animated: false)
        XCTAssertEqual(terminal.contentOffset.y, 80, accuracy: 2)

        // Fast producers replace the latest snapshot rather than appending
        // attachment copies or retaining a decode task for every frame.
        for revision in 2...30 {
            terminal.setOutput(output, images: [try imageWidget(revision: revision, size: CGSize(width: CGFloat(revision), height: 10)), staticImage], imageRevision: revision)
        }
        let latest = try await waitForImage(in: terminal, at: firstPosition, size: CGSize(width: 30, height: 10))
        XCTAssertTrue(latest === moving)
        XCTAssertTrue(attachment(in: terminal, at: secondPosition) === fixed)
        XCTAssertTrue(fixed.image === fixedPixels, "Unchanged images should reuse their decoded pixels")
        XCTAssertEqual(terminal.attributedText.string, text)
        XCTAssertEqual(terminal.selectedRange, NSRange(location: 0, length: 6))
        XCTAssertEqual(terminal.contentOffset.y, 80, accuracy: 2)
        XCTAssertFalse(terminal.followsOutput)

        // TextKit can compensate for an attachment in a deferred layout pass.
        // The viewport must remain stable after that pass as well.
        try await Task.sleep(nanoseconds: 50_000_000)
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, 80, accuracy: 2)
        terminal.resumeFollowing()
        XCTAssertEqual(terminal.contentOffset.y, terminal.bottomOffset, accuracy: 2)
        terminal.pauseFollowing()
        terminal.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        terminal.updateFollowPosition()
        terminal.setOutput(output, images: [try imageWidget(revision: 31, size: CGSize(width: 31, height: 10)), staticImage], imageRevision: 31)
        _ = try await waitForImage(in: terminal, at: firstPosition, size: CGSize(width: 31, height: 10))
        XCTAssertEqual(terminal.contentOffset.y, 120, accuracy: 2)
        terminal.selectionDidChange()
        terminal.setContentOffset(CGPoint(x: 0, y: 170), animated: false)
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, 170, accuracy: 2, "Find or selection navigation should release the animation viewport anchor")

        terminal.setOutput(output + "more text\n", images: [try imageWidget(revision: 31, size: CGSize(width: 31, height: 10)), staticImage], imageRevision: 31)
        XCTAssertTrue(attachment(in: terminal, at: firstPosition) === moving)
        XCTAssertTrue(terminal.attributedText.string.hasSuffix("after\nmore text\n"))
    }

    @MainActor
    func testLateImageDataFillsExistingMarkerAndEvictionReleasesPixels() async throws {
        let terminal = TerminalTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), textContainer: nil)
        let output = "before\n\u{001F}PYPHONE_IMAGE:7\u{001E}\nafter\n"
        terminal.setOutput(output, images: [], imageRevision: 0)
        let pending = try XCTUnwrap(attachment(in: terminal, at: 7))
        XCTAssertNil(pending.image)
        let size = CGSize(width: 30, height: 10)
        terminal.setOutput(output, images: [try imageWidget(revision: 1, size: size)], imageRevision: 1)
        let filled = try await waitForImage(in: terminal, at: 7, size: size)
        XCTAssertTrue(filled === pending)
        XCTAssertEqual(terminal.attributedText.string, "before\n\u{FFFC}\nafter\n")
        terminal.setOutput(output, images: [], imageRevision: 2)
        XCTAssertNil(pending.image, "Evicted images must not remain retained by text attachments")
        XCTAssertTrue(attachment(in: terminal, at: 7) === pending)
    }
}
