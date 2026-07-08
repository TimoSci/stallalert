import Foundation

public struct AlertPolicy: Sendable {
    public enum Cause: String, Equatable, Sendable { case predicted, measured }

    public struct Input: Sendable {
        public let forecastMinKn: Double?
        public let liveKn: Double?
        public let liveAgeSeconds: TimeInterval?
        public init(forecastMinKn: Double?, liveKn: Double?, liveAgeSeconds: TimeInterval?) {
            self.forecastMinKn = forecastMinKn; self.liveKn = liveKn; self.liveAgeSeconds = liveAgeSeconds
        }
    }

    private let thresholdKn: Double
    private let hysteresisKn: Double = 2
    private let maxLiveAge: TimeInterval = 20 * 60
    private var silenced = false

    public init(thresholdKn: Double) { self.thresholdKn = thresholdKn }

    public mutating func evaluate(_ input: Input) -> Cause? {
        let live: Double? = (input.liveAgeSeconds ?? .infinity) <= maxLiveAge ? input.liveKn : nil
        let values = [live, input.forecastMinKn].compactMap { $0 }
        guard !values.isEmpty else { return nil }

        let cause: Cause?
        if let l = live, l < thresholdKn { cause = .measured }
        else if let f = input.forecastMinKn, f < thresholdKn { cause = .predicted }
        else { cause = nil }

        guard let firing = cause else {
            if silenced && values.allSatisfy({ $0 >= thresholdKn + hysteresisKn }) { silenced = false }
            return nil
        }
        guard !silenced else { return nil }
        silenced = true
        return firing
    }
}
