import WatchKit
import AVFoundation
import os

@MainActor
final class AlertPresenter {
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private let log = Logger(subsystem: "net.timosci.StallAlert", category: "alert")

    // 3 rounds over ~21 s: each round = strong haptics burst + alarm tone,
    // separated by 8 s gaps (1.6 s haptics x 3 + 8 s x 2 gaps ~= 20.8 s).
    // Haptics must fire even when the audio path fails — never let an audio
    // error break the alarm.
    func fire() {
        // Cancel any running alarm WITHOUT deactivating the audio session:
        // prepareAudio re-activates immediately, and a detached deactivation
        // racing that activation could kill the new alarm's audio.
        cancelPlayback()
        task = Task {
            await prepareAudio()
            for round in 0..<3 {
                guard !Task.isCancelled else { break }
                for _ in 0..<4 {
                    WKInterfaceDevice.current().play(.failure)
                    try? await Task.sleep(for: .milliseconds(400))
                }
                player?.currentTime = 0
                player?.play()
                if round < 2 { try? await Task.sleep(for: .seconds(8)) }
            }
        }
    }

    // watchOS requires the ASYNC session activation before playback — the
    // synchronous setActive(true) is an iOS idiom that fails silently here.
    // Errors are logged, never swallowed: `log stream` / Xcode console shows
    // subsystem net.timosci.StallAlert when diagnosing a silent alarm.
    // (Note: watchOS Silent Mode still mutes app audio; haptics are the
    // guaranteed channel.)
    private func prepareAudio() async {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [])
            try await session.activate(options: [])
        } catch {
            log.error("audio session activation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "caf") else {
            log.error("alarm.caf missing from bundle")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.volume = 1.0
            player = p
        } catch {
            log.error("AVAudioPlayer init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        cancelPlayback()
        // Deactivation blocks the calling thread for seconds on watchOS —
        // tapping OK on an alert froze the whole UI here (observed live,
        // 2026-07-15). Fire-and-forget off the main actor; playback is
        // already stopped, so WHEN the session winds down doesn't matter.
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func cancelPlayback() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
    }
}
