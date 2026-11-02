import Foundation

enum QuotaCountdownFormatter {
    private static let secondsPerMinute: Int64 = 60
    private static let secondsPerHour: Int64 = 3_600
    private static let secondsPerDay: Int64 = 86_400

    static func string(until date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite, interval > 0 else { return "—" }

        // The quota API currently bounds its timestamps to supported calendar dates.
        // Keep this helper safe for unexpected dates too: avoid trapping integer casts.
        let roundedUp = ceil(interval)
        guard roundedUp.isFinite, roundedUp > 0, roundedUp < Double(Int64.max) else { return "—" }
        let totalSeconds = Int64(roundedUp)

        if totalSeconds >= secondsPerDay {
            let days = totalSeconds / secondsPerDay
            let hours = (totalSeconds % secondsPerDay) / secondsPerHour
            return "\(days)天\(hours)时"
        }
        if totalSeconds >= secondsPerHour {
            let hours = totalSeconds / secondsPerHour
            let minutes = (totalSeconds % secondsPerHour) / secondsPerMinute
            return "\(hours)时\(minutes)分"
        }
        if totalSeconds >= secondsPerMinute {
            let minutes = totalSeconds / secondsPerMinute
            let seconds = totalSeconds % secondsPerMinute
            return "\(minutes)分\(seconds)秒"
        }
        return "\(totalSeconds)秒"
    }
}
