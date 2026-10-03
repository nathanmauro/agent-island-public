import AppKit

import IslandCore

/// The island's one sound: system sound "Glass" at volume 0.35 (spec §7.3).
///
/// Only PeekCoordinator calls `play()`, and only in the call that presents a visible card, so every
/// sound has a visible card (spec §2). PeekWiring is the only place that constructs it.
@MainActor
final class ChimePlayer: ChimePlaying {
    private let sound: NSSound?
    private(set) var playedCount = 0

    init(soundName: String = IslandTiming.chimeSoundName, volume: Float = IslandTiming.chimeVolume) {
        // Copy the shared named instance so setting the volume never changes it for anyone else.
        let sound = NSSound(named: NSSound.Name(soundName))?.copy() as? NSSound
        sound?.volume = volume
        if sound == nil {
            NSLog("Agent Island could not load the chime sound %@", soundName)
        }
        self.sound = sound
    }

    /// Counts every chime the coordinator asked for (the state dump reports it), then plays it.
    /// A chime that is still sounding restarts rather than overlapping.
    func play() {
        playedCount += 1
        guard let sound else { return }
        if sound.isPlaying {
            sound.stop()
        }
        sound.play()
    }
}
