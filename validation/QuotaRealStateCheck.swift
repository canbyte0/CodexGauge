import AppKit
import Foundation

final class FakeTransport: QuotaTransport {
 var onNotification: ((String) -> Void)?
 var onExit: (() -> Void)?
 var onEvent: ((String) -> Void)?
 var starts: [(Result<Void, Error>) -> Void] = []
 var accounts: [(Result<[String: Any], Error>) -> Void] = []
 var reads: [(Result<[String: Any], Error>) -> Void] = []
 var stops = 0
 func start(_ done: @escaping (Result<Void, Error>) -> Void) { starts.append(done) }
 func account(_ done: @escaping (Result<[String: Any], Error>) -> Void) { accounts.append(done) }
 func limits(_ done: @escaping (Result<[String: Any], Error>) -> Void) { reads.append(done) }
 func stop() { stops += 1 }
 func stopAndWait() { stops += 1 }
}

@main struct StateCheck {
 @MainActor static func drain() async { for _ in 0..<8 { await Task.yield() }; try? await Task.sleep(nanoseconds: 10_000_000) }
 @MainActor static func check(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { fatalError("FAIL: \(name)") } }
 static let account: [String: Any] = ["account": ["type": "chatgpt"]]
 static func response(_ used: Int, accountID: String = "a") -> [String: Any] {
  ["accountId": accountID, "rateLimits": ["limitId": "codex", "primary": ["windowDurationMins": 300, "usedPercent": used, "resetsAt": 2_000_000_000], "secondary": ["windowDurationMins": 10080, "usedPercent": 25, "resetsAt": 2_000_000_000]], "rateLimitResetCredits": ["availableCount": 0]]
 }
 @MainActor static func main() async {
  let transport = FakeTransport()
  var time = Date(timeIntervalSince1970: 1_000_000)
  let model = QuotaWindowModel(provider: transport, now: { time })
  model.startClock(); check(transport.starts.count == 1, "start")
  transport.starts[0](.success(())); await drain()
  check(transport.accounts.count == 1, "account check")
  transport.accounts[0](.success(account)); await drain()
  check(transport.reads.count == 1 && model.loading, "initial request")
  model.refresh(); model.refresh(); check(transport.reads.count == 1, "single in flight")
  transport.reads[0](.success(response(20))); await drain()
  check(model.snapshot != nil && model.statusText == "已更新", "first success")
  let firstObserved = model.snapshot!.observedAt
  time.addTimeInterval(1); model.refresh(); check(transport.reads.count == 2, "manual request")
  let retry = time.addingTimeInterval(500)
  transport.reads[1](.failure(QuotaRealProvider.Failure.server(retry))); await drain()
  check(model.snapshot?.observedAt == firstObserved && model.stale, "failure retains last time and marks stale")
  model.refresh(); model.stopClock(); model.startClock(); transport.onNotification?("account/rateLimits/updated"); await drain()
  check(transport.reads.count == 2 && transport.starts.count == 1, "cooldown covers refresh resume and push")
  time = retry.addingTimeInterval(1); model.startClock(); check(transport.reads.count == 3, "read after cooldown")
  transport.reads[2](.success(response(30))); await drain()
  check(model.statusText == "已更新", "recovery")
  model.refresh(); check(transport.reads.count == 4, "pre switch read")
  transport.onNotification?("account/updated"); await drain()
  check(model.snapshot == nil && transport.stops == 0 && transport.starts.count == 1, "source data clears without restarting the CLI session")
  transport.reads[3](.success(response(1))); await drain()
  check(model.snapshot == nil, "old request discarded")
  check(transport.accounts.count == 2, "stale read triggers post-event account verification")
  transport.accounts[1](.success(account)); await drain()
  check(transport.reads.count == 5, "fresh source read")
  transport.reads[4](.success(response(60, accountID: "a"))); await drain()
  check(model.snapshot != nil && QuotaRealParser.percent(model.snapshot!.fiveHour.remaining) == "40%", "verified current source accepted")
  model.refresh(); transport.reads[5](.success(response(5, accountID: "c"))); await drain()
  check(model.snapshot == nil && transport.starts.count == 2, "changed account ID clears and reconnects")
  model.shutdown()
  let second = FakeTransport()
  var now2 = Date(timeIntervalSince1970: 1_000_000)
  let m2 = QuotaWindowModel(provider: second, now: { now2 })
  m2.startClock(); second.starts[0](.success(())); await drain()
  second.accounts[0](.success(["account": NSNull()])); await drain()
  check(m2.statusText == "需要登录" && second.reads.isEmpty, "missing login never reads quota")
  m2.refresh(); check(second.accounts.count == 2, "login can be rechecked")
  second.accounts[1](.success(account)); await drain()
  second.reads[0](.success(response(20))); await drain()
  now2.addTimeInterval(121); m2.startClock()
  check(m2.stale && m2.statusText == "已过期", "120 second staleness")
  second.reads[1](.success(response(20))); await drain()
  second.onExit?(); await drain()
  check(m2.snapshot == nil && m2.statusText == "无法连接", "transport loss clears snapshot")
  now2.addTimeInterval(61); m2.startClock()
  check(second.starts.count == 2, "transport loss reconnects")
  m2.shutdown()
  let third = FakeTransport()
  let m3 = QuotaWindowModel(provider: third, now: { now2 })
  m3.startClock(); third.starts[0](.success(())); await drain(); third.accounts[0](.success(account)); await drain()
  let bucketA: [String: Any] = ["limitId": "a", "primary": ["windowDurationMins": 300, "usedPercent": 20]]
  let bucketB: [String: Any] = ["limitId": "b", "primary": ["windowDurationMins": 300, "usedPercent": 80, "resetsAt": now2.timeIntervalSince1970 + 5]]
  let buckets: [String: Any] = ["rateLimitsByLimitId": ["a": bucketA, "b": bucketB]]
  third.reads[0](.success(buckets)); await drain()
  check(m3.snapshot == nil && m3.choices == ["a", "b"], "multi bucket requires choice")
  m3.select("a"); check(third.reads.count == 2, "selected bucket read")
  m3.select("b"); check(third.reads.count == 2, "no bucket switch while read pending")
  third.reads[1](.success(buckets)); await drain()
  check(m3.snapshot?.bucketID == "a", "selected bucket only")
  m3.select("b"); check(m3.snapshot == nil && third.reads.count == 3, "switch clears old bucket")
  third.reads[2](.success(buckets)); await drain()
  check(m3.snapshot?.bucketID == "b" && QuotaRealParser.percent(m3.snapshot!.fiveHour.remaining) == "20%", "new bucket not mixed")
  now2.addTimeInterval(6); m3.startClock()
  check(m3.snapshot != nil && m3.expired(m3.snapshot!.fiveHour) && m3.statusText == "等待更新", "reset expiry without local refill")
  check(QuotaRealParser.percent(m3.snapshot!.fiveHour.remaining) == "20%", "expiry preserves last recorded value")
  m3.shutdown()
  print("PASS production model: single in-flight, retry cooldown, login, failure/staleness, resume, notification, generation isolation, account-id change and transport loss")
 }
}
