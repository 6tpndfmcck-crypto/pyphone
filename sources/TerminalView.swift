import SwiftUI
import UIKit

final class TerminalTextView: UITextView {
    private(set) var followsOutput = true
    private var renderedOutput: String?
    private var renderedImageRevision = -1
    private var imageCache: [Int: UIImage] = [:]
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

    func setOutput(_ output: String, images: [Widget], imageRevision: Int) {
        guard renderedOutput != output || renderedImageRevision != imageRevision else { return }
        let oldOffset = contentOffset
        if output.isEmpty || renderedOutput == nil || renderedOutput?.isEmpty == true {
            followsOutput = true
        }
        if renderedImageRevision != imageRevision {
            imageCache.removeAll()
            for widget in images where widget.kind == "image" {
                if let encoded = widget.image_data,
                   let bytes = Data(base64Encoded: encoded),
                   let image = UIImage(data: bytes) {
                    imageCache[widget.id] = image
                }
            }
        }
        renderedOutput = output
        renderedImageRevision = imageRevision

        // The output stream contains lightweight image positions. Substitute
        // native text attachments, keeping print(), errors, and images ordered.
        let marker = try! NSRegularExpression(pattern: "\u{001F}PYPHONE_IMAGE:([0-9]+)\u{001E}")
        let source = output as NSString
        let result = NSMutableAttributedString(string: "")
        var cursor = 0
        for match in marker.matches(in: output, range: NSRange(location: 0, length: source.length)) {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            result.append(ANSIConsoleRenderer.render(source.substring(with: before), fontSize: consoleFontSize))
            let identifier = Int(source.substring(with: match.range(at: 1))) ?? -1
            if let image = imageCache[identifier] {
                let attachment = NSTextAttachment()
                attachment.image = image
                let availableWidth = min(380, max(160, bounds.width - textContainerInset.left - textContainerInset.right - 16))
                let scale = min(1, availableWidth / max(image.size.width, 1), 480 / max(image.size.height, 1))
                attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(ANSIConsoleRenderer.render("[Image unavailable]", fontSize: consoleFontSize))
            }
            cursor = NSMaxRange(match.range)
        }
        let remainder = NSRange(location: cursor, length: source.length - cursor)
        result.append(ANSIConsoleRenderer.render(source.substring(with: remainder), fontSize: consoleFontSize))
        attributedText = output.isEmpty
            ? ANSIConsoleRenderer.render("Console output appears here.", fontSize: consoleFontSize)
            : result
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
    var images: [Widget] = []
    var imageRevision = 0
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
        view.setOutput(output, images: images, imageRevision: imageRevision)
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

