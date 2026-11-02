import Foundation

@main
struct QuotaCountdownFormatCheck {
    static func main() {
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        func formatted(_ seconds: TimeInterval) -> String {
            QuotaCountdownFormatter.string(until: base.addingTimeInterval(seconds), now: base)
        }

        let cases: [(String, String, String)] = [
            ("days-hours", formatted(4 * 86_400 + 15 * 3_600 + 59 * 60 + 59), "4天15时"),
            ("hours-minutes", formatted(3 * 3_600 + 42 * 60 + 59), "3时42分"),
            ("minutes-seconds", formatted(42 * 60 + 18), "42分18秒"),
            ("seconds", formatted(18), "18秒"),
            ("future-subsecond-rounds-up", formatted(0.001), "1秒"),
            ("minute-boundary", formatted(60), "1分0秒"),
            ("hour-boundary", formatted(3_600), "1时0分"),
            ("day-boundary", formatted(86_400), "1天0时"),
            ("already-due", formatted(0), "—"),
            ("past", formatted(-1), "—"),
            ("infinite-date", QuotaCountdownFormatter.string(until: Date(timeIntervalSince1970: .infinity), now: base), "—"),
            ("huge-date", QuotaCountdownFormatter.string(until: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude), now: base), "—"),
        ]

        for (name, actual, expected) in cases {
            guard actual == expected else {
                fputs("FAIL \(name): expected=\(expected) actual=\(actual)\n", stderr)
                exit(1)
            }
            print("PASS \(name): \(actual)")
        }

        let start = base
        let afterOneSecond = start.addingTimeInterval(1)
        let before = QuotaCountdownFormatter.string(until: start.addingTimeInterval(18), now: start)
        let after = QuotaCountdownFormatter.string(until: start.addingTimeInterval(18), now: afterOneSecond)
        guard before == "18秒", after == "17秒" else {
            fputs("FAIL clock-advance: \(before) -> \(after)\n", stderr)
            exit(1)
        }
        print("PASS clock-advance: \(before) -> \(after)")
        print("PASS cases=\(cases.count + 1)")
    }
}
