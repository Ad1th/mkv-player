import AppKit

/// Keyboard shortcuts are handled here, before anything else sees the event.
/// AVPlayerView toggles playback on space by itself, so handling space in a
/// local event monitor meant two toggles per press and nothing happened.
final class PlayerApplication: NSApplication {
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

let app = PlayerApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
