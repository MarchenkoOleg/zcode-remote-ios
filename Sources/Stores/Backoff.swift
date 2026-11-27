import Foundation

nonisolated struct Backoff: Sendable, Equatable {
    private let base: TimeInterval
    private let cap: TimeInterval
    private(set) var attempt: Int

    init(base: TimeInterval = 0.5, cap: TimeInterval = 30, attempt: Int = 0) {
        self.base = base
        self.cap = cap
        self.attempt = attempt
    }

    mutating func nextDelay() -> TimeInterval {
        let delay = min(cap, base * pow(2, Double(attempt)))
        attempt += 1
        return delay
    }

    mutating func reset() {
        attempt = 0
    }
}
