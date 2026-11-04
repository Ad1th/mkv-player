import AVFoundation
import MediaToolbox

/// Lets the volume go past 100%, up to 200%, for quiet files on laptop speakers.
/// AVPlayer stops at 1.0, so the extra gain is applied in an audio tap, with a
/// soft knee instead of hard clipping so loud scenes don't crackle.
enum VolumeBoost {
    /// Extra gain on top of the player's volume. Read on the audio thread.
    nonisolated(unsafe) static var gain: Float = 1

    /// A mix with a tap on every audio track, so switching tracks keeps the boost.
    static func audioMix(for asset: AVAsset) async -> AVAudioMix? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.compactMap { track in
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: nil,
                init: nil, finalize: nil, prepare: nil, unprepare: nil, process: process)
            var tap: MTAudioProcessingTap?
            guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
                  let tap else { return nil }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            return params
        }
        return mix
    }

    /// AVPlayer hands taps deinterleaved 32-bit float.
    private static let process: MTAudioProcessingTapProcessCallback = { tap, frames, _, buffers, framesOut, flagsOut in
        guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
        let gain = VolumeBoost.gain
        guard gain > 1 else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                let x = samples[i] * gain
                let level = abs(x)
                // Straight up to 0.8, then bend smoothly towards 1.0.
                samples[i] = level <= 0.8 ? x : (x < 0 ? -1 : 1) * (0.8 + 0.2 * tanh((level - 0.8) / 0.2))
            }
        }
    }
}
