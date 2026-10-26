import SwiftUI
import UIKit

final class TerminalTextView: UITextView {
    private(set) var followsOutput = true
    private var renderedOutput: String?
    var consoleFontSize: CGFloat = 14 {
        didSet { if oldValue != consoleFontSize { renderedOutput = nil } }
    }

    var bottomOffset: CGFloat {
        max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
    }

    func updateFollowPosition() {
        followsOutput = bottomOffset - contentOffset.y <= 24
    }

    func pauseFollowing() {
        followsOutput = false
    }

    func setOutput(_ output: String) {
        guard renderedOutput != output else { return }
        let oldOffset = contentOffset
        // Clearing the terminal or starting its first output resumes following.
        if output.isEmpty || renderedOutput == nil || renderedOutput?.isEmpty == true {
            followsOutput = true
        }
        renderedOutput = output
        attributedText = ANSIConsoleRenderer.render(output.isEmpty ? "Console output appears here." : output, fontSize: consoleFontSize)
        layoutManager.ensureLayout(for: textContainer)
        layoutIfNeeded()
        if followsOutput && !isTracking && !isDragging && !isDecelerating {
            scrollToBottom()
        } else {
            setContentOffset(oldOffset, animated: false)
        }
    }

    func scrollToBottom() {
        let target = CGPoint(x: 0, y: bottomOffset)
        if abs(contentOffset.y - target.y) > 0.5 {
            setContentOffset(target, animated: false)
        }
    }

    func resumeFollowing() {
        followsOutput = true
        scrollToBottom()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Also follow after resizing the terminal or showing the Window tab.
        if followsOutput && !isTracking && !isDragging && !isDecelerating {
            scrollToBottom()
        }
    }
}

struct TerminalView: UIViewRepresentable {
    let output: String
    var fontSize: CGFloat = 14
    var followRequest = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerminalTextView {
        let view = TerminalTextView(frame: .zero, textContainer: nil)
        view.consoleFontSize = fontSize
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.isFindInteractionEnabled = true
        view.accessibilityIdentifier = "consoleOutput"
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 5, bottom: 10, right: 5)
        view.delegate = context.coordinator
        context.coordinator.lastFollowRequest = followRequest
        view.setOutput(output)
        return view
    }

    func updateUIView(_ view: TerminalTextView, context: Context) {
        view.consoleFontSize = fontSize
        view.setOutput(output)
        if context.coordinator.lastFollowRequest != followRequest {
            context.coordinator.lastFollowRequest = followRequest
            view.resumeFollowing()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TerminalTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var lastFollowRequest = 0
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            (scrollView as? TerminalTextView)?.pauseFollowing()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView.isDragging || scrollView.isDecelerating else { return }
            (scrollView as? TerminalTextView)?.updateFollowPosition()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { (scrollView as? TerminalTextView)?.updateFollowPosition() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            (scrollView as? TerminalTextView)?.updateFollowPosition()
        }
    }
}

