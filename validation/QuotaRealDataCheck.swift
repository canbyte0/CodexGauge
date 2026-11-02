import Foundation

@main struct QuotaRealDataCheck {
 static var count = 0
 static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
  count += 1
  if !condition() { fatalError("FAIL: \(name)") }
 }
 static func object(_ primary: [String: Any]?, _ secondary: [String: Any]?, id: String = "codex") -> [String: Any] {
  ["limitId": id, "primary": primary as Any? ?? NSNull(), "secondary": secondary as Any? ?? NSNull()]
 }
 static func window(_ mins: Int, _ used: Any, _ reset: Any = 2_000_000_000) -> [String: Any] { ["windowDurationMins": mins, "usedPercent": used, "resetsAt": reset] }
 static func snap(_ root: [String: Any], selection: String? = nil) -> QuotaSnapshot {
  guard case .snapshot(let s, _) = QuotaRealParser.parse(root, selection: selection, now: Date(timeIntervalSince1970: 1000)) else { fatalError("expected snapshot") }; return s
 }
 static func credit(_ id: String, resetType: String = "codexRateLimits", status: String = "available", expiresAt: Any = NSNull(), includeExpiry: Bool = true) -> [String: Any] {
  var value: [String: Any] = ["id": id, "resetType": resetType, "status": status]
  if includeExpiry { value["expiresAt"] = expiresAt }
  return value
 }
 static func resetSnap(_ count: Any, credits: Any? = nil, includeCredits: Bool = true) -> QuotaSnapshot {
  var summary: [String: Any] = ["availableCount": count]
  if includeCredits { summary["credits"] = credits ?? NSNull() }
  return snap(["rateLimits": object(window(300, 25), window(10080, 40)), "rateLimitResetCredits": summary])
 }
 static func creditLines(_ lines: [QuotaResetCreditLine]) -> [(Int, QuotaResetCreditExpiry, Bool, Bool)] {
  lines.compactMap { line in
   if case .credit(let ordinal, let expiry, let expired, let stale) = line { return (ordinal, expiry, expired, stale) }
   return nil
  }
 }
 static func notes(_ lines: [QuotaResetCreditLine]) -> [String] {
  lines.compactMap { line in if case .note(let text, _) = line { return text }; return nil }
 }
 static func main() {
  let a = object(window(10080, 20), window(300, 50))
  let root: [String: Any] = ["rateLimits": object(window(300, 99), nil), "rateLimitsByLimitId": ["codex": a], "rateLimitResetCredits": ["availableCount": 0, "credits": [1,2,3]]]
  let s = snap(root)
  check(QuotaRealParser.percent(s.fiveHour.remaining) == "50%", "select codex and duration")
  check(QuotaRealParser.percent(s.week.remaining) == "80%", "swapped windows")
  check(QuotaRealParser.count(s.resets) == "0 次", "authoritative zero count")
  check(s.fiveHour.reset?.timeIntervalSince1970 == 2_000_000_000, "unix seconds")
  check(QuotaRealParser.percent(.value(0)) == "0%", "zero")
  check(QuotaRealParser.percent(.value(100)) == "100%", "hundred")
  check(QuotaRealParser.percent(.value(0.2)) == "<1%", "small remaining")
  check(QuotaRealParser.percent(.value(99.8)) == ">99%", "below hundred")
  check(QuotaRealParser.percent(QuotaRealParser.remaining(101)) == "异常", "range")
  check(QuotaRealParser.percent(QuotaRealParser.remaining(true)) == "异常", "bool")
  check(QuotaRealParser.percent(QuotaRealParser.remaining(NSNull())) == "未知", "null")
  let duplicate = snap(["rateLimits": object(window(300, 10), window(300, 20))])
  check(QuotaRealParser.percent(duplicate.fiveHour.remaining) == "异常", "duplicate window")
  check(QuotaRealParser.percent(duplicate.week.remaining) == "未知", "missing window")
  let badtime = snap(["rateLimits": object(window(300, 10, "bad"), nil)])
  check(badtime.fiveHour.reset == nil && QuotaRealParser.percent(badtime.fiveHour.remaining) == "90%", "invalid reset independent")
  check(QuotaRealParser.count(badtime.resets) == "未提供", "missing credits unsupported")
  let negative = snap(["rateLimits": a, "rateLimitResetCredits": ["availableCount": -1]])
  check(QuotaRealParser.count(negative.resets) == "异常", "negative count")
  let single = snap(["rateLimitsByLimitId": ["other": object(window(300, 30), nil, id: "other")]])
  check(single.bucketID == "other", "single bucket")
  let multi: [String: Any] = ["rateLimitsByLimitId": ["a": object(nil, nil, id: "a"), "b": object(nil, nil, id: "b")], "rateLimits": a]
  if case .choose(let ids) = QuotaRealParser.parse(multi, now: Date()) { check(ids == ["a", "b"], "multi choose") } else { fatalError("multi should require choice") }
  check(snap(multi, selection: "b").bucketID == "b", "selected bucket")
  if case .invalid = QuotaRealParser.parse(["rateLimitsByLimitId": ["codex": object(nil, nil, id: "other")], "rateLimits": a], now: Date()) { check(true, "mismatch invalid") } else { fatalError("mismatch must fail") }
  if case .invalid = QuotaRealParser.parse(["rateLimitsByLimitId": "bad", "rateLimits": a], now: Date()) { check(true, "malformed multi") } else { fatalError("bad multi must fail") }
  let other = snap(["rateLimits": object(window(15, 10), window(60, 20))])
  check(QuotaRealParser.percent(other.fiveHour.remaining) == "未知" && QuotaRealParser.percent(other.week.remaining) == "未知", "other durations not guessed")
  let nullCredits = snap(["rateLimits": a, "rateLimitResetCredits": NSNull()])
  check(QuotaRealParser.count(nullCredits.resets) == "未知", "null count")
  let overflow = snap(["rateLimits": a, "rateLimitResetCredits": ["availableCount": 1e30]])
  check(QuotaRealParser.count(overflow.resets) == "异常", "overflow count")
  check(QuotaRealParser.percent(QuotaRealParser.remaining(0)) == "100%" && QuotaRealParser.percent(QuotaRealParser.remaining(100)) == "0%", "used endpoints")
  check(QuotaRealParser.percent(QuotaRealParser.remaining(99.8)) == "<1%" && QuotaRealParser.percent(QuotaRealParser.remaining(0.2)) == ">99%", "used edge mapping")
  let multiExpiry = resetSnap(3, credits: [
   credit("late", expiresAt: 3000),
   credit("same-a", expiresAt: 2000),
   credit("same-b", expiresAt: 2000)
  ])
  let ordered = creditLines(QuotaResetCreditPresentation.lines(snapshot: multiExpiry, now: Date(timeIntervalSince1970: 1000), stale: false))
  check(ordered.count == 3, "each available credit has a row")
  check(ordered.map { $0.0 } == [1, 2, 3], "display ordinals follow expiry order")
  check(ordered.map { $0.1 } == [.date(Date(timeIntervalSince1970: 2000)), .date(Date(timeIntervalSince1970: 2000)), .date(Date(timeIntervalSince1970: 3000))], "ascending expiry with equal-time rows preserved")

  let nullAndMissing = resetSnap(2, credits: [credit("never", expiresAt: NSNull()), credit("unknown", includeExpiry: false)])
  let nullLines = QuotaResetCreditPresentation.lines(snapshot: nullAndMissing, now: Date(timeIntervalSince1970: 1000), stale: false)
  let nullExpiryCredits = creditLines(nullLines)
  check(nullExpiryCredits.count == 2 && nullExpiryCredits.contains { $0.1 == .never } && nullExpiryCredits.contains { $0.1 == .unknown }, "explicit null means never; missing expiry stays unknown")
  check(notes(nullLines).contains("部分到期明细异常"), "missing expiry is surfaced as anomaly")
  let invalidExpiry = resetSnap(1, credits: [credit("bad", expiresAt: true)])
  check(creditLines(QuotaResetCreditPresentation.lines(snapshot: invalidExpiry, now: Date(), stale: false)).first?.1 == .unknown, "invalid expiry does not become never")

  let unavailableArray = resetSnap(2, credits: NSNull())
  check(notes(QuotaResetCreditPresentation.lines(snapshot: unavailableArray, now: Date(), stale: false)) == ["到期时间未提供"], "null credits report unavailable dates")
  let missingArray = resetSnap(2, includeCredits: false)
  check(notes(QuotaResetCreditPresentation.lines(snapshot: missingArray, now: Date(), stale: false)) == ["到期时间未提供"], "missing credits report unavailable dates")
  let emptyArray = resetSnap(2, credits: [Any]())
  check(notes(QuotaResetCreditPresentation.lines(snapshot: emptyArray, now: Date(), stale: false)) == ["另2次未提供到期时间"], "empty array retains authoritative count")
  let partial = resetSnap(3, credits: [credit("one", expiresAt: 2000)])
  let partialLines = QuotaResetCreditPresentation.lines(snapshot: partial, now: Date(timeIntervalSince1970: 1000), stale: false)
  check(creditLines(partialLines).count == 1 && notes(partialLines).contains("另2次未提供到期时间"), "partial array shows known row and remainder")
  let zero = resetSnap(0, credits: [credit("must-not-show", expiresAt: 2000)])
  check(QuotaResetCreditPresentation.lines(snapshot: zero, now: Date(), stale: false).isEmpty, "zero authoritative count never invents rows")

  let filtered = resetSnap(2, credits: [
   credit("redeemed", status: "redeemed", expiresAt: 2000),
   credit("redeeming", status: "redeeming", expiresAt: 2000),
   credit("wrong-type", resetType: "unknown", expiresAt: 2000)
  ])
  check(creditLines(QuotaResetCreditPresentation.lines(snapshot: filtered, now: Date(), stale: false)).isEmpty, "non-available and unknown types are not presented as available")
  let old = resetSnap(1, credits: [credit("expired", expiresAt: 900)])
  let oldLines = QuotaResetCreditPresentation.lines(snapshot: old, now: Date(timeIntervalSince1970: 1000), stale: true)
  check(creditLines(oldLines).first?.2 == true && creditLines(oldLines).first?.3 == true, "expired stale snapshot keeps expired and stale markers")
  check(notes(oldLines).isEmpty, "one valid stale detail needs no count note")
  let contradictory = resetSnap(1, credits: [credit("duplicate", expiresAt: 2000), credit("duplicate", expiresAt: 3000)])
  let contradictoryLines = QuotaResetCreditPresentation.lines(snapshot: contradictory, now: Date(), stale: false)
  check(creditLines(contradictoryLines).isEmpty && notes(contradictoryLines).contains("部分到期明细异常"), "duplicate ids are not presented as distinct credits")
  check(QuotaRealParser.percent(contradictory.fiveHour.remaining) == "75%", "malformed detail does not invalidate quota windows")

  print("PASS \(count) production parser checks")
 }
}
