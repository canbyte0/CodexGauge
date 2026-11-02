import AppKit
import Foundation

final class Transport85: QuotaTransport {
 var onNotification: ((String) -> Void)?; var onExit: (() -> Void)?; var onEvent: ((String) -> Void)?
 var starts: [(Result<Void, Error>)->Void] = []; var accounts: [(Result<[String: Any], Error>)->Void] = []; var reads: [(Result<[String: Any], Error>)->Void] = []; var stops = 0
 func start(_ f: @escaping (Result<Void, Error>)->Void) { starts.append(f) }
 func account(_ f: @escaping (Result<[String: Any], Error>)->Void) { accounts.append(f) }
 func limits(_ f: @escaping (Result<[String: Any], Error>)->Void) { reads.append(f) }
 func stop() { stops += 1 }; func stopAndWait() { stops += 1 }
}
@main struct Check85 {
 @MainActor static func drain() async { for _ in 0..<10 { await Task.yield() }; try? await Task.sleep(nanoseconds: 5_000_000) }
 @MainActor static func check(_ b: @autoclosure ()->Bool, _ s: String) { if !b() { fatalError("FAIL: " + s) } }
 static let account: [String: Any] = ["account": ["type": "chatgpt"]]
 static let quota: [String: Any] = ["accountId": "account-a", "rateLimits": ["limitId": "codex", "primary": ["windowDurationMins": 300, "usedPercent": 50, "resetsAt": 2000000000]]]
 @MainActor static func main() async {
  let t = Transport85(); var now = Date(timeIntervalSince1970: 1000000)
  let m = QuotaWindowModel(provider:t, now:{now})
  m.startClock(); t.starts[0](.success(())); await drain(); m.startClock()
  check(t.accounts.count == 1, "resume cannot duplicate account check")
  t.accounts[0](.success(account)); await drain()
  for (idx, delay) in [60.0, 120.0, 300.0].enumerated() {
   check(t.reads.count == idx + 1, "failure request exists")
   t.reads[idx](.failure(QuotaRealProvider.Failure.timeout)); await drain()
   t.onNotification?("account/rateLimits/updated"); await drain()
   now.addTimeInterval(delay - 1); m.stopClock(); m.startClock(); m.testTick()
   check(t.reads.count == idx + 1, "failure backoff blocks push and resume")
   now.addTimeInterval(1); m.testTick(); check(t.reads.count == idx + 2, "retry after deadline")
  }
  t.reads[3](.success(quota)); await drain()
  now.addTimeInterval(59); m.testTick(); check(t.reads.count == 4, "success restores 60s cadence")
  now.addTimeInterval(1); m.testTick(); check(t.reads.count == 5, "next normal poll")
  t.reads[4](.failure(QuotaRealProvider.Failure.timeout)); await drain(); m.refresh()
  check(t.reads.count == 6, "manual retry may bypass ordinary backoff")
  let retry = now.addingTimeInterval(500); t.reads[5](.failure(QuotaRealProvider.Failure.server(retry))); await drain()
  t.onNotification?("account/rateLimits/updated"); await drain(); now.addTimeInterval(400); m.stopClock(); m.startClock(); m.refresh(); m.testTick()
  check(t.reads.count == 6, "service cooldown applies to all triggers")
  now = retry; m.testTick(); check(t.reads.count == 7, "service cooldown ends")
  t.reads[6](.success(quota)); await drain()
  let oldNotification = t.onNotification!, oldExit = t.onExit!
  m.refresh(); check(t.reads.count == 8, "before account change")
  t.onNotification?("account/updated"); await drain()
  check(m.snapshot == nil && t.starts.count == 1, "account change clears before in-session verification")
  t.reads[7](.success(quota)); await drain(); t.accounts[1](.success(account)); await drain(); t.reads[8](.success(quota)); await drain()
  oldNotification("account/rateLimits/updated"); oldExit(); t.reads[7](.success(["rateLimits": ["limitId": "old"]])); await drain()
  check(m.snapshot?.bucketID == "codex" && t.starts.count == 1 && !m.loading, "old callbacks do not poison verified account snapshot=\(m.snapshot?.bucketID ?? "nil") starts=\(t.starts.count) loading=\(m.loading)")
  let count = t.reads.count; now.addTimeInterval(1); m.stopClock(); now.addTimeInterval(100); m.testTick()
  check(t.reads.count == count, "closed or hidden stops poll")
  m.startClock(); check(t.reads.count == count+1, "show performs one stale recovery read")
  t.reads[count](.success(quota)); await drain(); m.sleep(); now.addTimeInterval(5); m.testTick(); m.wake(); check(t.reads.count == count+1, "recent snapshot reused after wake")
  m.sleep(); now.addTimeInterval(11); m.wake(); check(t.reads.count == count+2, "wake performs one older recovery read")
  m.shutdown(); print("PASS 85 state: 60/120/300, recovery, cooldown, generations, lifecycle and one-at-a-time")
 }
}
