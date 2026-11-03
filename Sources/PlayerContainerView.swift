import AppKit

/// The window's content view: accepts dropped files and reports mouse movement
/// so the overlay buttons can come and go with the playback controls.
final class PlayerContainerView: NSView {
    var onDrop: ((URL) -> Void)?
    var onMouseMove: (() -> Void)?
    var onMouseExit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onMouseMove?() }
    override func mouseEntered(with event: NSEvent) { onMouseMove?() }
    override func mouseExited(with event: NSEvent) { onMouseExit?() }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let url = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return false }
        onDrop?(url)
        return true
    }
}

/// A round frosted button that sits over the video, styled like AVKit's own controls.
final class OverlayButton: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let blur = NSVisualEffectView()

    init(symbol: String, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        addSubview(blur)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        icon.contentTintColor = .white
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { alphaValue = 0.6 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
