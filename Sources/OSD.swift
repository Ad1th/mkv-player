import AppKit

/// A small message at the top of the video that fades out on its own,
/// for feedback on keyboard actions ("+10 s · 12:44", "Volume 80%").
final class OSD: NSView {
    private let blur = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var hide: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 3
        addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, for seconds: TimeInterval = 1) {
        guard let parent = superview else { return }
        label.stringValue = text
        let size = label.sizeThatFits(NSSize(width: 520, height: 200))
        let w = ceil(size.width) + 28, h = ceil(size.height) + 14
        frame = NSRect(x: (parent.bounds.width - w) / 2, y: parent.bounds.height - h - 28, width: w, height: h)
        blur.frame = bounds
        label.frame = NSRect(x: 14, y: 7, width: w - 28, height: h - 14)
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            animator().alphaValue = 1
        }
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.animator().alphaValue = 0
            }, completionHandler: { if self?.alphaValue == 0 { self?.isHidden = true } })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let s = Int(max(0, seconds).rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
