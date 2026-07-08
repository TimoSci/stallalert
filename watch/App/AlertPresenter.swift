import WatchKit
import AVFoundation

@MainActor
final class AlertPresenter {
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?

    // 3 rounds over ~21 s: each round = strong haptics burst + alarm tone,
    // separated by 8 s gaps (1.6 s haptics x 3 + 8 s x 2 gaps ~= 20.8 s).
    func fire() {
        stop()
        task = Task {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, options: [])
            try? session.setActive(true)
            if let url = Bundle.main.url(forResource: "alarm", withExtension: "caf") {
                player = try? AVAudioPlayer(contentsOf: url)
            }
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

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
