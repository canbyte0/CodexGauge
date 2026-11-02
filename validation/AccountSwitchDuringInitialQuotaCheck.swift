import AppKit
import Foundation
final class InitialSwitchTransport: QuotaTransport {
 var onNotification: ((String)->Void)?; var onExit: (()->Void)?; var onEvent: ((String)->Void)?
 var starts: [(Result<Void, Error>)->Void] = []; var accounts: [(Result<[String:Any], Error>)->Void] = []; var reads: [(Result<[String:Any], Error>)->Void] = []
 func start(_ f: @escaping (Result<Void,Error>)->Void) { starts.append(f) }
 func account(_ f: @escaping (Result<[String:Any],Error>)->Void) { accounts.append(f) }
 func limits(_ f: @escaping (Result<[String:Any],Error>)->Void) { reads.append(f) }
 func stop() {}; func stopAndWait() {}
}
@main struct InitialSwitchCheck {
 @MainActor static func drain() async { for _ in 0..<12 { await Task.yield() }; try? await Task.sleep(nanoseconds: 5_000_000) }
 @MainActor static func main() async {
  let t = InitialSwitchTransport(); let m = QuotaWindowModel(provider:t, refreshPolicy:.backgroundEvery60Seconds)
  m.startBackgroundRefresh(); t.starts[0](.success(())); await drain()
  t.accounts[0](.success(["account":["type":"chatgpt","email":"first@example.invalid"]])); await drain()
  guard t.reads.count == 1 else { print("FAIL: first quota not started"); m.shutdown(); exit(1) }
  t.onNotification?("account/updated"); await drain()
  t.reads[0](.success(["accountId":"old-account","rateLimits":["limitId":"codex","primary":["windowDurationMins":300,"usedPercent":90,"resetsAt":2_000_000_000]]])); await drain()
  let oldPublished = m.snapshot != nil
  print(oldPublished ? "FAIL: initial quota result published after an unclassified real account change" : "PASS: unclassified account change blocks old initial quota result")
  print("TRACE accountChecks=\(t.accounts.count) quotaReads=\(t.reads.count)")
  m.shutdown(); exit(oldPublished ? 1 : 0)
 }
}
