import AVFoundation
import MediaPlayer

/// The play/pause key, AirPods taps and the Now Playing widget in Control Center.
/// Next and previous track go to the next and previous episode.
final class NowPlaying {
    struct Actions {
        var toggle: () -> Void
        var play: () -> Void
        var pause: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var skip: (Double) -> Void
        var seek: (Double) -> Void
    }

    private var rateObservation: NSKeyValueObservation?

    init(player: AVPlayer, actions a: Actions) {
        let c = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ run: @escaping (MPRemoteCommandEvent) -> Void) {
            command.addTarget { event in
                DispatchQueue.main.async { run(event) }
                return .success
            }
        }
        on(c.togglePlayPauseCommand) { _ in a.toggle() }
        on(c.playCommand) { _ in a.play() }
        on(c.pauseCommand) { _ in a.pause() }
        on(c.nextTrackCommand) { _ in a.next() }
        on(c.previousTrackCommand) { _ in a.previous() }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        on(c.skipForwardCommand) { _ in a.skip(10) }
        on(c.skipBackwardCommand) { _ in a.skip(-10) }
        on(c.changePlaybackPositionCommand) { e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { a.seek(e.positionTime) }
        }
        rateObservation = player.observe(\.rate) { [weak self] player, _ in
            DispatchQueue.main.async { self?.update(player) }
        }
    }

    var title = ""

    /// Elapsed time and rate are enough for the system to keep the clock moving,
    /// so this only needs calling when something changes.
    func update(_ player: AVPlayer) {
        let center = MPNowPlayingInfoCenter.default()
        guard let item = player.currentItem else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
        ]
        if item.duration.isNumeric { info[MPMediaItemPropertyPlaybackDuration] = item.duration.seconds }
        center.nowPlayingInfo = info
        center.playbackState = player.rate == 0 ? .paused : .playing
    }
}
