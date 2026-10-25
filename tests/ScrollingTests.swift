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
        terminal.setOutput(output)
        terminal.layoutIfNeeded()
        XCTAssertGreaterThan(terminal.bottomOffset, 0)
        XCTAssertEqual(terminal.contentOffset.y, terminal.bottomOffset, accuracy: 2)

        terminal.setOutput(output + "new output\n")
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, terminal.bottomOffset, accuracy: 2)

        // Model a user drag away from the bottom, then append more output.
        terminal.pauseFollowing()
        terminal.setContentOffset(CGPoint(x: 0, y: 80), animated: false)
        terminal.updateFollowPosition()
        XCTAssertFalse(terminal.followsOutput)
        terminal.setOutput(output + "new output\nmore output\n")
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, 80, accuracy: 2)

        terminal.scrollToBottom()
        terminal.updateFollowPosition()
        XCTAssertTrue(terminal.followsOutput)
        terminal.setOutput(output + "last line\n")
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, terminal.bottomOffset, accuracy: 2)

        terminal.pauseFollowing()
        terminal.setOutput("")
        XCTAssertTrue(terminal.followsOutput)
        terminal.setOutput(output)
        terminal.layoutIfNeeded()
        XCTAssertEqual(terminal.contentOffset.y, terminal.bottomOffset, accuracy: 2)
    }
}
