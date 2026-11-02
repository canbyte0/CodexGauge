import Foundation
import CoreFoundation

enum QuotaField<T> {
    case value(T), unknown, invalid, unsupported
}

struct QuotaWindowValue {
    let remaining: QuotaField<Double>
    let reset: Date?
}

enum QuotaResetCreditExpiry: Equatable {
    case date(Date)
    case never
    case unknown
}

struct QuotaResetCreditDetail: Equatable {
    let expiry: QuotaResetCreditExpiry
    let sourceOrder: Int
}

struct QuotaResetCreditDetails {
    // nil means the backend did not provide a credit array. An empty array is an explicit result.
    let credits: [QuotaResetCreditDetail]?
    let hasAnomalies: Bool
}

enum QuotaResetCreditLine: Equatable {
    case credit(ordinal: Int, expiry: QuotaResetCreditExpiry, expired: Bool, stale: Bool)
    case note(String, stale: Bool)
}

enum QuotaResetCreditPresentation {
    static func lines(snapshot: QuotaSnapshot, now: Date, stale: Bool) -> [QuotaResetCreditLine] {
        let availableCount: Int?
        if case .value(let value) = snapshot.resets { availableCount = value }
        else { availableCount = nil }

        // The service count is authoritative. A zero never creates detail rows.
        if availableCount == 0 { return [] }

        guard let credits = snapshot.resetCreditDetails.credits else {
            if let availableCount, availableCount > 0 {
                let note = snapshot.resetCreditDetails.hasAnomalies ? "到期明细异常" : "到期时间未提供"
                return [.note(note, stale: stale)]
            }
            return snapshot.resetCreditDetails.hasAnomalies ? [.note("到期明细异常", stale: stale)] : []
        }

        let ordered = credits.enumerated().sorted { left, right in
            let leftRank = expiryRank(left.element.expiry)
            let rightRank = expiryRank(right.element.expiry)
            if leftRank != rightRank { return leftRank < rightRank }
            if case .date(let leftDate) = left.element.expiry,
               case .date(let rightDate) = right.element.expiry,
               leftDate != rightDate {
                return leftDate < rightDate
            }
            return left.element.sourceOrder < right.element.sourceOrder
        }.map(\.element)

        if let availableCount, ordered.count > availableCount {
            // Contradictory detail cannot be reconciled with the authoritative count.
            return [.note("次数与明细不一致", stale: stale)]
        }

        var result = ordered.enumerated().map { index, credit -> QuotaResetCreditLine in
            let expired: Bool
            if case .date(let date) = credit.expiry { expired = date <= now }
            else { expired = false }
            return .credit(ordinal: index + 1, expiry: credit.expiry, expired: expired, stale: stale)
        }

        if let availableCount, availableCount > ordered.count {
            result.append(.note("另\(availableCount - ordered.count)次未提供到期时间", stale: stale))
        }
        if snapshot.resetCreditDetails.hasAnomalies {
            result.append(.note("部分到期明细异常", stale: stale))
        }
        return result
    }

    private static func expiryRank(_ expiry: QuotaResetCreditExpiry) -> Int {
        switch expiry {
        case .date: 0
        case .unknown: 1
        case .never: 2
        }
    }
}

struct QuotaSnapshot {
    let bucketID: String
    let bucketName: String
    let fiveHour: QuotaWindowValue
    let week: QuotaWindowValue
    let resets: QuotaField<Int>
    let resetCreditDetails: QuotaResetCreditDetails
    let observedAt: Date
}

enum QuotaParseResult {
    case snapshot(QuotaSnapshot, [String])
    case choose([String])
    case invalid
}

enum QuotaRealParser {
    static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }
    static func remaining(_ raw: Any?) -> QuotaField<Double> {
        guard let raw, !(raw is NSNull) else { return .unknown }
        guard let v = number(raw), (0...100).contains(v) else { return .invalid }
        return .value(100-v)
    }
    static func percent(_ field: QuotaField<Double>) -> String {
        switch field {
        case .unknown: return "未知"
        case .invalid: return "异常"
        case .unsupported: return "未提供"
        case .value(let v):
            if v > 0 && v < 1 { return "<1%" }
            if v < 100 && v > 99 { return ">99%" }
            return "\(Int(v.rounded()))%"
        }
    }
    static func count(_ field: QuotaField<Int>) -> String {
        switch field {
        case .unknown: return "未知"
        case .invalid: return "异常"
        case .unsupported: return "未提供"
        case .value(let v): return "\(v) 次"
        }
    }

    private static func resetCreditDetails(_ raw: Any?) -> QuotaResetCreditDetails {
        guard let raw, !(raw is NSNull), let summary = raw as? [String: Any],
              let rawCredits = summary["credits"], !(rawCredits is NSNull) else {
            return QuotaResetCreditDetails(credits: nil, hasAnomalies: false)
        }
        guard let credits = rawCredits as? [Any] else {
            return QuotaResetCreditDetails(credits: nil, hasAnomalies: true)
        }

        var hasAnomalies = false
        var byID: [String: QuotaResetCreditDetail] = [:]
        var conflictedIDs = Set<String>()
        for (index, rawCredit) in credits.enumerated() {
            guard let credit = rawCredit as? [String: Any] else {
                hasAnomalies = true
                continue
            }
            guard let resetType = credit["resetType"] as? String else {
                hasAnomalies = true
                continue
            }
            guard resetType == "codexRateLimits" else {
                if resetType != "unknown" { hasAnomalies = true }
                continue
            }
            guard let status = credit["status"] as? String else {
                hasAnomalies = true
                continue
            }
            guard status == "available" else {
                if status != "redeeming" && status != "redeemed" && status != "unknown" { hasAnomalies = true }
                continue
            }
            guard let id = credit["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                hasAnomalies = true
                continue
            }

            let expiry: QuotaResetCreditExpiry
            if let rawExpiry = credit["expiresAt"] {
                if rawExpiry is NSNull {
                    expiry = .never
                } else if let seconds = number(rawExpiry),
                          seconds >= -62_135_596_800, seconds < 253_402_300_800 {
                    expiry = .date(Date(timeIntervalSince1970: seconds))
                } else {
                    expiry = .unknown
                    hasAnomalies = true
                }
            } else {
                expiry = .unknown
                hasAnomalies = true
            }

            if conflictedIDs.contains(id) { continue }
            if byID.removeValue(forKey: id) != nil {
                conflictedIDs.insert(id)
                hasAnomalies = true
                continue
            }
            byID[id] = QuotaResetCreditDetail(expiry: expiry, sourceOrder: index)
        }

        return QuotaResetCreditDetails(
            credits: byID.values.sorted { $0.sourceOrder < $1.sourceOrder },
            hasAnomalies: hasAnomalies
        )
    }

    static func parse(_ root: [String: Any], selection: String? = nil, now: Date) -> QuotaParseResult {
        var bucket: [String: Any]
        var selected: String
        var choices: [String] = []
        if let multi = root["rateLimitsByLimitId"], !(multi is NSNull) {
            guard let buckets = multi as? [String: Any], !buckets.isEmpty else { return .invalid }
            choices = buckets.keys.sorted()
            if let selection { guard buckets[selection] != nil else { return .invalid }; selected = selection }
            else if buckets["codex"] != nil { selected = "codex" }
            else if buckets.count == 1 { selected = choices[0] }
            else { return .choose(choices) }
            guard let parsed = buckets[selected] as? [String: Any] else { return .invalid }
            if let id = parsed["limitId"] as? String, id != selected { return .invalid }
            bucket = parsed
        } else {
            guard selection == nil, let parsed = root["rateLimits"] as? [String: Any] else { return .invalid }
            bucket = parsed
            selected = (parsed["limitId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "默认额度桶（旧接口）"
        }
        let name = (bucket["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? selected
        func window(_ minutes: Int) -> QuotaWindowValue {
            let values = [bucket["primary"], bucket["secondary"]].compactMap { $0 as? [String: Any] }
                .filter { number($0["windowDurationMins"]) == Double(minutes) }
            guard values.count == 1 else { return QuotaWindowValue(remaining: values.isEmpty ? .unknown : .invalid, reset: nil) }
            let v = values[0]
            var date: Date?
            if let seconds = number(v["resetsAt"]), seconds > 0, seconds < 253402300800 { date = Date(timeIntervalSince1970: seconds) }
            return QuotaWindowValue(remaining: remaining(v["usedPercent"]), reset: date)
        }
        let resetSummary = root["rateLimitResetCredits"] as? [String: Any]
        let resetCount: QuotaField<Int>
        if root["rateLimitResetCredits"] == nil { resetCount = .unsupported }
        else if root["rateLimitResetCredits"] is NSNull { resetCount = .unknown }
        else if let credits = resetSummary {
            if credits["availableCount"] == nil || credits["availableCount"] is NSNull { resetCount = .unknown }
            else if let n = number(credits["availableCount"]), n >= 0, n.rounded(.towardZero) == n, n < Double(Int.max) { resetCount = .value(Int(n)) }
            else { resetCount = .invalid }
        } else { resetCount = .invalid }
        return .snapshot(QuotaSnapshot(
            bucketID: selected,
            bucketName: name,
            fiveHour: window(300),
            week: window(10080),
            resets: resetCount,
            resetCreditDetails: resetCreditDetails(root["rateLimitResetCredits"]),
            observedAt: now
        ), choices)
    }
}
