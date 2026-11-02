import AppKit
import Foundation

@main struct TransportCheck85 {
 @MainActor static func until(_ condition: ()->Bool, _ name: String) async {
  for _ in 0..<300 { if condition() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
  fatalError("FAIL timeout: " + name)
 }
 @MainActor static func check(_ b: @autoclosure ()->Bool, _ name: String) { if !b() { fatalError("FAIL: " + name) } }
 @MainActor static func main() async {
  let fixture = FileManager.default.currentDirectoryPath + "/validation/quota85-test-server.pl"
  for mode in ["init-exit", "account-exit", "oversize", "write-failure", "child-exit"] {
   let arg = (mode == "write-failure" || mode == "child-exit") ? "good" : mode
   let provider = QuotaRealProvider(testCommand: ("/usr/bin/perl", [fixture, arg]))
   var now = Date(timeIntervalSince1970: 1000000)
   let model = QuotaWindowModel(provider: provider, now: { now })
   var events: [String] = []
   model.onEvent = { events.append($0) }
   model.startClock()
   if arg == "good" {
    await until({ model.snapshot != nil && !model.loading }, mode + " initial")
    if mode == "write-failure" { provider.testBreakInput(); model.refresh() }
    else { provider.testTerminateChild() }
   }
   await until({ !model.loading && model.statusText == "无法连接" }, mode + " failure")
   check(model.snapshot == nil, mode + " clears visible value")
   now.addTimeInterval(61); model.testTick()
   print("TRACE \(mode) status=\(model.statusText) loading=\(model.loading) events=\(events)")
   await until({ events.filter { $0.hasPrefix("provider-start") }.count >= 2 }, mode + " reconnect")
   model.shutdown()
   print("PASS real provider pipeline: \(mode), failure reaches model and reconnects")
  }
 }
}
