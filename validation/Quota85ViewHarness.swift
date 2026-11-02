import AppKit
import Foundation

// Compiled only in a separate QUOTA_TESTING app. No real provider is instantiated.
@MainActor final class HarnessClock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
final class HarnessTransport: QuotaTransport {
 var onNotification: ((String) -> Void)?; var onExit: (() -> Void)?; var onEvent: ((String) -> Void)?
 let scenario: String; var count = 0; var afterFirst: (() -> Void)?
 init(_ scenario: String) { self.scenario = scenario }
 func start(_ done: @escaping (Result<Void, Error>) -> Void) { done(.success(())) }
 func account(_ done: @escaping (Result<[String: Any], Error>) -> Void) { done(.success(["account": ["type": "chatgpt"]])) }
 func limits(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
  count += 1
  if count > 1 && scenario == "failed" { done(.failure(QuotaRealProvider.Failure.timeout)); return }
  if count > 1 && (scenario == "loading" || scenario == "stale") { return }
  let usage: Any = scenario == "zero" ? 100 : scenario == "invalid" ? -4 : 23
  let primary: Any = scenario == "unknown" ? NSNull() : ["windowDurationMins": 300, "usedPercent": usage, "resetsAt": 2_000_000_000] as [String: Any]
  let secondary: Any = scenario == "unknown" ? NSNull() : ["windowDurationMins": 10080, "usedPercent": usage, "resetsAt": 2_000_000_000] as [String: Any]
  let name = scenario == "long" ? String(repeating: "很长的额度来源名称用于验证显示", count: 12) : "测试额度桶"
  let result: [String: Any] = ["rateLimits": ["limitId": "codex", "limitName": name, "primary": primary, "secondary": secondary], "rateLimitResetCredits": scenario == "unknown" ? NSNull() : ["availableCount": scenario == "zero" ? 0 : 2] as Any]
  done(.success(result))
  if count == 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.afterFirst?() } }
 }
 func stop() {}; func stopAndWait() {}
}

@MainActor final class AcceptanceDelegate: NSObject, NSApplicationDelegate {
 let clock = HarnessClock(); let transport: HarnessTransport; let model: QuotaWindowModel
 var controller: QuotaWindowController?; var log: DemoRuntimeLog?
 init(scenario: String) {
  let t = HarnessTransport(scenario); transport = t
  let c = clock; model = QuotaWindowModel(provider: t, now: { c.now })
  super.init()
  t.afterFirst = { [weak self] in
   guard let self else { return }
   if scenario == "stale" { self.clock.now.addTimeInterval(121); self.model.testClockOnly() }
   if scenario == "failed" || scenario == "loading" { self.model.refresh() }
  }
 }
 func applicationDidFinishLaunching(_ notification: Notification) {
  do {
   let directory = try OverlayRuntimePaths.runtimeDirectory(); log = try DemoRuntimeLog(directory: directory)
   controller = QuotaWindowController(model: model, log: log!); controller?.showSummaryWindow()
  } catch { NSApp.terminate(nil) }
 }
 func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
 func applicationWillTerminate(_ notification: Notification) { model.shutdown(); controller?.prepareForTermination(); log?.close() }
}
@main @MainActor struct Quota85ViewMain {
 static func main() {
  let args = CommandLine.arguments
  let scenario = args.firstIndex(of: "--scenario").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "failed"
  guard ["unknown", "zero", "invalid", "stale", "long", "failed", "loading"].contains(scenario) else { return }
  let app = NSApplication.shared; app.setActivationPolicy(.regular)
  let delegate = AcceptanceDelegate(scenario: scenario); app.delegate = delegate; app.run()
 }
}
