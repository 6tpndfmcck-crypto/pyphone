import SwiftUI
import UIKit
import ImageIO

final class TerminalTextView: UITextView {
    private struct ImageSource {
        let revision: Int
        let encoded: String
    }
    private struct CachedImage {
        let revision: Int
        let image: UIImage?
    }
    private struct ImageSlot {
        let attachment: NSTextAttachment
        let range: NSRange
    }

    private(set) var followsOutput = true
    private var renderedOutput: String?
    private var renderedImageRevision = -1
    private var imageSources: [Int: ImageSource] = [:]
    private var imageCache: [Int: CachedImage] = [:]
    private var imageSlots: [Int: [ImageSlot]] = [:]
    private var decodeInFlight = false
    private var preservingPosition = false
    // UITextView may adjust contentOffset in a later layout pass after an
    // attachment or selection changes. Keep the image-frame viewport anchored
    // until text, the viewport, or an explicit user scroll changes it.
    private var imageViewportOffset: CGPoint?
    private var laidOutSize: CGSize = .zero
    // One batch in flight per terminal; newer snapshots replace imageSources
    // rather than queuing a decoding task for every animation frame.
    private let imageQueue = DispatchQueue(label: "py.console.images", qos: .userInitiated)
    private static let marker = try! NSRegularExpression(pattern: "\u{001F}PYPHONE_IMAGE:([0-9]+)\u{001E}")

    var consoleFontSize: CGFloat = 14 {
        didSet { if oldValue != consoleFontSize { renderedOutput = nil } }
    }

    var bottomOffset: CGFloat {
        max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
    }

    func updateFollowPosition() {
        imageViewportOffset = nil
        followsOutput = bottomOffset - contentOffset.y <= 24
    }

    func pauseFollowing() {
        imageViewportOffset = nil
        followsOutput = false
    }

    func selectionDidChange() {
        if !preservingPosition { imageViewportOffset = nil }
    }

    private func restoreImageViewport(_ offset: CGPoint) {
        let anchor = CGPoint(x: offset.x, y: min(max(offset.y, -adjustedContentInset.top), bottomOffset))
        imageViewportOffset = anchor
        if contentOffset != anchor { setContentOffset(anchor, animated: false) }
    }

    func setOutput(_ output: String, images: [Widget], imageRevision: Int) {
        let textChanged = renderedOutput != output
        guard textChanged || renderedImageRevision != imageRevision else { return }
        if textChanged || isTracking || isDragging || isDecelerating {
            imageViewportOffset = nil
        } else if imageViewportOffset == nil {
            imageViewportOffset = contentOffset
        }
        if renderedImageRevision != imageRevision {
            imageSources = Dictionary(uniqueKeysWithValues: images.compactMap { widget in
                guard widget.kind == "image", let encoded = widget.image_data else { return nil }
                return (widget.id, ImageSource(revision: widget.image_revision, encoded: encoded))
            })
            // Eviction must also release raster data held by attachments, not
            // just dictionary entries. Keep the slot and its dimensions.
            for id in imageCache.keys where imageSources[id] == nil {
                for slot in imageSlots[id] ?? [] {
                    slot.attachment.image = nil
                    layoutManager.invalidateDisplay(forCharacterRange: slot.range)
                }
            }
            imageCache = imageCache.filter { imageSources[$0.key] != nil }
        }
        renderedImageRevision = imageRevision
        if textChanged {
            let oldOffset = contentOffset
            if output.isEmpty || renderedOutput == nil || renderedOutput?.isEmpty == true {
                followsOutput = true
            }
            renderedOutput = output
            rebuildText(output)
            layoutManager.ensureLayout(for: textContainer)
            layoutIfNeeded()
            if followsOutput && !isTracking && !isDragging && !isDecelerating {
                scrollToBottom()
            } else {
                setContentOffset(oldOffset, animated: false)
            }
        }
        decodeLatestImages()
    }

    private func attachmentBounds(for image: UIImage?) -> CGRect {
        let availableWidth = min(380, max(1, bounds.width - textContainerInset.left - textContainerInset.right - 16))
        guard let image = image else {
            return CGRect(x: 0, y: 0, width: min(300, availableWidth), height: 24)
        }
        let scale = min(1, availableWidth / max(image.size.width, 1), 480 / max(image.size.height, 1))
        return CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
    }

    private func rebuildText(_ output: String) {
        let source = output as NSString
        let result = NSMutableAttributedString(string: "")
        let previousSlots = imageSlots
        var slots: [Int: [ImageSlot]] = [:]
        var cursor = 0
        for match in Self.marker.matches(in: output, range: NSRange(location: 0, length: source.length)) {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            result.append(ANSIConsoleRenderer.render(source.substring(with: before), fontSize: consoleFontSize))
            let identifier = Int(source.substring(with: match.range(at: 1))) ?? -1
            let occurrence = slots[identifier]?.count ?? 0
            let old = previousSlots[identifier] ?? []
            let attachment = occurrence < old.count ? old[occurrence].attachment : NSTextAttachment()
            attachment.image = imageCache[identifier]?.image
            attachment.bounds = attachmentBounds(for: attachment.image)
            let range = NSRange(location: result.length, length: 1)
            result.append(NSAttributedString(attachment: attachment))
            slots[identifier, default: []].append(ImageSlot(attachment: attachment, range: range))
            cursor = NSMaxRange(match.range)
        }
        let remainder = NSRange(location: cursor, length: source.length - cursor)
        result.append(ANSIConsoleRenderer.render(source.substring(with: remainder), fontSize: consoleFontSize))
        imageSlots = slots
        attributedText = output.isEmpty
            ? ANSIConsoleRenderer.render("Console output appears here.", fontSize: consoleFontSize)
            : result
    }

    private func decodeLatestImages() {
        guard !decodeInFlight else { return }
        let pending = imageSources.filter { id, source in
            imageSlots[id] != nil && imageCache[id]?.revision != source.revision
        }
        guard !pending.isEmpty else { return }
        decodeInFlight = true
        imageQueue.async { [weak self] in
            var decoded: [Int: CachedImage] = [:]
            for (id, source) in pending {
                let image: UIImage? = autoreleasepool {
                    guard let data = Data(base64Encoded: source.encoded),
                          let input = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let cgImage = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1024
                          ] as CFDictionary) else { return nil }
                    // ImageIO preserves alpha; no opaque bitmap or disk frame.
                    return UIImage(cgImage: cgImage)
                }
                decoded[id] = CachedImage(revision: source.revision, image: image)
            }
            let completed = decoded
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.decodeInFlight = false
                var updates: [Int: CachedImage] = [:]
                for (id, value) in completed where self.imageSources[id] != nil {
                    if value.revision >= (self.imageCache[id]?.revision ?? -1) {
                        updates[id] = value
                    }
                }
                self.applyImages(updates)
                // Show each completed batch even if the producer has advanced;
                // discarding every superseded decode could starve a fast loop.
                // Only one batch can complete at once, so frames stay ordered.
                self.decodeLatestImages()
            }
        }
    }

    private func applyImages(_ updates: [Int: CachedImage]) {
        guard !updates.isEmpty else { return }
        let userScrolling = isTracking || isDragging || isDecelerating
        if userScrolling { imageViewportOffset = nil }
        let oldOffset = imageViewportOffset ?? contentOffset
        let oldSelection = selectedRange
        let firstImage = updates.contains { imageCache[$0.key] == nil && $0.value.image != nil }
        preservingPosition = true
        for (id, value) in updates {
            imageCache[id] = value
            for slot in imageSlots[id] ?? [] {
                let bounds = attachmentBounds(for: value.image)
                let sizeChanged = slot.attachment.bounds != bounds
                slot.attachment.image = value.image
                slot.attachment.bounds = bounds
                if sizeChanged {
                    layoutManager.invalidateLayout(forCharacterRange: slot.range, actualCharacterRange: nil)
                }
                layoutManager.invalidateDisplay(forCharacterRange: slot.range)
            }
        }
        layoutIfNeeded()
        if selectedRange != oldSelection { selectedRange = oldSelection }
        // Follow once when a newly created image's dimensions become known.
        // Subsequent frames never move the user's console viewport.
        if firstImage && followsOutput && !isTracking && !isDragging && !isDecelerating {
            scrollToBottom()
            imageViewportOffset = contentOffset
        } else if !userScrolling {
            restoreImageViewport(oldOffset)
        }
        preservingPosition = false
    }

    func scrollToBottom() {
        imageViewportOffset = nil
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
        if isTracking || isDragging || isDecelerating { imageViewportOffset = nil }
        super.layoutSubviews()
        let viewportChanged = bounds.size != laidOutSize
        if viewportChanged {
            imageViewportOffset = nil
            laidOutSize = bounds.size
            for slots in imageSlots.values {
                for slot in slots {
                    slot.attachment.bounds = attachmentBounds(for: slot.attachment.image)
                    layoutManager.invalidateLayout(forCharacterRange: slot.range, actualCharacterRange: nil)
                }
            }
        }
        if viewportChanged && !preservingPosition && followsOutput && !isTracking && !isDragging && !isDecelerating {
            scrollToBottom()
        } else if let offset = imageViewportOffset {
            // Also undo delayed TextKit offset compensation after the async
            // decode callback has returned; one immediate restoration is not
            // sufficient when attachment geometry invalidates layout.
            restoreImageViewport(offset)
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
        view.setOutput(output, images: images, imageRevision: imageRevision)
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
        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? TerminalTextView)?.selectionDidChange()
        }

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

