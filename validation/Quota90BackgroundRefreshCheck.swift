import AppKit
import Foundation

@MainActor
final class Scheduler90: QuotaTickScheduling {
    private(set) var starts = 0
    private(set) var stops = 0
    private var tick: (@MainActor () -> Void)?
    func start(_ tick: @escaping @MainActor () -> Void) {
        guard self.tick == nil else { return }
        starts += 1
        self.tick = tick
    }
    func stop() { if tick != nil { stops += 1 }; tick = nil }
    func fire() { tick?() }
}

final class Transport90: QuotaTransport {
    var onNotification: ((String) -> Void)?
    var onExit: (() -> Void)?
    var onEvent: ((String) -> Void)?
    var starts: [(Result<Void, Error>) -> Void] = []
    var accounts: [(Result<[String: Any], Error>) -> Void] = []
    var reads: [(Result<[String: Any], Error>) -> Void] = []
    private(set) var stops = 0
    private(set) var waits = 0
    func start(_ done: @escaping (Result<Void, Error>) -> Void) { starts.append(done) }
    func account(_ done: @escaping (Result<[String: Any], Error>) -> Void) { accounts.append(done) }
    func limits(_ done: @escaping (Result<[String: Any], Error>) -> Void) { reads.append(done) }
    func stop() { stops += 1 }
    func stopAndWait() { waits += 1 }
}

@main
struct Quota90BackgroundRefreshCheck {
    static let account: [String: Any] = ["account": ["type": "chatgpt", "email": "first@example.invalid"]]
    static func quota(_ accountID: String? = "test-account") -> [String: Any] {
        var response: [String: Any] = ["rateLimits": [
            "limitId": "codex", "primary": ["windowDurationMins": 300, "usedPercent": 50, "resetsAt": 2_000_000_000]
        ]]
        if let accountID { response["accountId"] = accountID }
        return response
    }

    @MainActor static func drain() async {
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError("FAIL: \(message)") }
    }

    @MainActor static func exerciseStdioProvider(mode: String, serverPath: String, switchesAccount: Bool = false) async {
        let provider = QuotaRealProvider(testCommand: ("/usr/bin/perl", [serverPath, mode]))
        let scheduler = Scheduler90()
        var now = Date(timeIntervalSince1970: 3_000_000)
        let model = QuotaWindowModel(provider: provider, now: { now }, refreshPolicy: .backgroundEvery60Seconds, scheduler: scheduler)
        var events: [String] = []
        model.onEvent = { events.append($0) }
        model.startBackgroundRefresh()

        for _ in 0..<120 {
            await drain()
            if model.snapshot != nil { break }
        }
        check(model.snapshot != nil, "real provider + stdio fixture publishes first snapshot for \(mode)")
        check(events.filter { $0.hasPrefix("provider-start") }.count == 1, "stdio fixture starts one provider for \(mode)")
        check(events.filter { $0.hasPrefix("provider-stop") }.isEmpty, "stdio account notification does not stop provider for \(mode)")
        check(events.filter { $0.contains("rpc-send method=account/read") }.count == (switchesAccount ? 3 : 2),
              "stdio account/read count is coalesced for \(mode): \(events)")
        check(events.contains { $0.contains("account-update handling=coalesced") }, "stdio account update is classified without identity data for \(mode)")
        check(!events.contains { $0.contains("first@example.invalid") || $0.contains("second@example.invalid") }, "runtime events contain no account address")

        let originalObservedAt = model.snapshot!.observedAt
        let readsAfterStartup = events.filter { $0.contains("rpc-send method=account/rateLimits/read") }.count
        now.addTimeInterval(59); scheduler.fire(); await drain()
        check(events.filter { $0.contains("rpc-send method=account/rateLimits/read") }.count == readsAfterStartup,
              "stdio fixture respects 59 second deadline for \(mode)")
        now.addTimeInterval(1); scheduler.fire()
        for _ in 0..<120 {
            await drain()
            if model.snapshot?.observedAt != originalObservedAt { break }
        }
        check(events.filter { $0.contains("rpc-send method=account/rateLimits/read") }.count == readsAfterStartup + 1,
              "stdio fixture performs one stable 60 second refresh for \(mode)")
        check(events.filter { $0.hasPrefix("provider-start") }.count == 1 && events.filter { $0.hasPrefix("provider-stop") }.isEmpty,
              "stdio polling keeps its single session for \(mode)")
        model.shutdown()
        await drain()
    }

    @MainActor static func main() async {
        let transport = Transport90(), scheduler = Scheduler90()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let model = QuotaWindowModel(provider: transport, now: { now }, refreshPolicy: .backgroundEvery60Seconds, scheduler: scheduler)

        // Opening the UI before the service starts must stay presentation-only.
        model.startClock(); model.showDetails(contentHeight: 600); model.showSummary(); model.stopClock()
        check(transport.starts.isEmpty && scheduler.starts == 0, "details cannot start a background session")
        model.startBackgroundRefresh(); model.startBackgroundRefresh()
        check(transport.starts.count == 1 && scheduler.starts == 1, "startup creates one session and one scheduler")
        transport.starts[0](.success(())); await drain()
        transport.onNotification?("account/updated"); await drain()
        check(transport.starts.count == 1 && transport.accounts.count == 1,
              "account notification does not restart provider while first check is in flight")
        transport.accounts[0](.success(account)); await drain()
        check(transport.accounts.count == 2 && transport.reads.isEmpty,
              "account notification during the initial check causes one post-event verification")
        transport.accounts[1](.success(account)); await drain()
        check(transport.reads.count == 1, "startup reads quota without opening details")
        transport.reads[0](.success(quota())); await drain()

        // Opening/closing at fresh, >10s and stale ages never fetches or moves the deadline.
        now.addTimeInterval(15)
        model.startClock(); model.showDetails(contentHeight: 600); model.stopClock(); model.showSummary()
        check(transport.reads.count == 1 && scheduler.starts == 1 && scheduler.stops == 0, "presentation after 10s leaves poll untouched")
        transport.onNotification?("account/rateLimits/updated"); await drain()
        check(transport.reads.count == 1, "idle sparse notice does not pull next read forward")
        now.addTimeInterval(44); scheduler.fire()
        check(transport.reads.count == 1, "59 second deadline does not run")
        now.addTimeInterval(1); scheduler.fire()
        check(transport.reads.count == 2, "60 second deadline runs once")
        scheduler.fire(); model.refresh(); transport.onNotification?("account/rateLimits/updated"); await drain()
        check(transport.reads.count == 2, "overlap, manual duplicate, and sparse notice coalesce")
        transport.reads[1](.success(quota())); await drain()
        now.addTimeInterval(121)
        model.startClock(); model.stopClock()
        check(transport.reads.count == 2 && transport.starts.count == 1 && transport.accounts.count == 2,
              "idle stale presentation does not read, validate, or reconnect")

        // Manual refresh is retained and success starts a fresh 60 second interval.
        model.refresh(); check(transport.reads.count == 3, "manual refresh starts one read")
        transport.reads[2](.success(quota())); await drain()
        now.addTimeInterval(59); scheduler.fire()
        check(transport.reads.count == 3, "manual success resets the interval")
        now.addTimeInterval(1); scheduler.fire()
        check(transport.reads.count == 4, "poll resumes 60 seconds after manual success")
        transport.reads[3](.success(quota())); await drain()

        // An in-flight reply may complete during sleep. Wake keeps its new deadline, then catches up once.
        model.refresh(); check(transport.reads.count == 5, "manual refresh before sleep starts one request")
        model.sleep(); now.addTimeInterval(30)
        transport.reads[4](.success(quota())); await drain()
        model.wake()
        check(transport.reads.count == 5, "early wake retains deadline after an in-flight sleep reply")
        model.sleep(); now.addTimeInterval(70); model.wake(); model.wake()
        check(transport.reads.count == 6, "overdue wake catches up once")
        scheduler.fire(); check(transport.reads.count == 6, "wake does not create a duplicate timer request")
        transport.reads[5](.success(quota())); await drain()

        // Background polling retains the established 60/120/300 retry ladder and server cooldown.
        now.addTimeInterval(59); scheduler.fire()
        check(transport.reads.count == 6, "periodic retry waits through second 59")
        now.addTimeInterval(1); scheduler.fire()
        check(transport.reads.count == 7, "periodic poll starts on second 60")
        transport.reads[6](.failure(QuotaRealProvider.Failure.timeout)); await drain()
        for (delay, readIndex) in [(60.0, 7), (120.0, 8), (300.0, 9)] {
            now.addTimeInterval(delay - 1); scheduler.fire()
            check(transport.reads.count == readIndex, "failure backoff waits (Int(delay) - 1) seconds")
            now.addTimeInterval(1); scheduler.fire()
            check(transport.reads.count == readIndex + 1, "failure backoff runs at (Int(delay)) seconds")
            transport.reads[readIndex](.failure(QuotaRealProvider.Failure.timeout)); await drain()
        }
        now.addTimeInterval(299); scheduler.fire()
        check(transport.reads.count == 10, "third backoff waits through second 299")
        now.addTimeInterval(1); scheduler.fire()
        check(transport.reads.count == 11, "third backoff runs at second 300")
        let retryAfter = now.addingTimeInterval(500)
        transport.reads[10](.failure(QuotaRealProvider.Failure.server(retryAfter))); await drain()
        model.refresh(); check(transport.reads.count == 11, "manual refresh respects server cooldown")
        now.addTimeInterval(499); scheduler.fire()
        check(transport.reads.count == 11, "server cooldown holds until Retry-After")
        now.addTimeInterval(1); scheduler.fire()
        check(transport.reads.count == 12, "server cooldown expires at Retry-After")
        transport.reads[11](.success(quota())); await drain()
        model.refresh(); check(transport.reads.count == 13, "manual retry can bypass ordinary backoff")
        transport.reads[12](.failure(QuotaRealProvider.Failure.timeout)); await drain()
        model.refresh(); check(transport.reads.count == 14, "manual retry starts after ordinary failure")

        let statusAtShutdown = model.statusText
        model.shutdown(); model.shutdown(); scheduler.fire()
        transport.reads[13](.success(quota())); await drain()
        check(transport.reads.count == 14 && transport.waits == 1 && scheduler.stops == 3 && model.statusText == statusAtShutdown,
              "shutdown cancels timer and rejects in-flight transport callbacks idempotently")

        // Error, transport loss and login-required snapshots also remain presentation-only.
        let errorTransport = Transport90(), errorScheduler = Scheduler90()
        let errorNow = Date(timeIntervalSince1970: 2_000_000)
        let errorModel = QuotaWindowModel(provider: errorTransport, now: { errorNow }, refreshPolicy: .backgroundEvery60Seconds, scheduler: errorScheduler)
        errorModel.startBackgroundRefresh(); errorTransport.starts[0](.success(())); await drain()
        errorTransport.accounts[0](.success(account)); await drain()
        errorTransport.reads[0](.failure(QuotaRealProvider.Failure.timeout)); await drain()
        errorModel.startClock(); errorModel.stopClock()
        check(errorTransport.starts.count == 1 && errorTransport.accounts.count == 1 && errorTransport.reads.count == 1,
              "failed presentation does not reconnect or retry")
        errorTransport.onExit?(); await drain()
        errorModel.startClock(); errorModel.stopClock()
        check(errorTransport.starts.count == 1 && errorTransport.accounts.count == 1,
              "disconnected presentation does not reconnect")
        errorModel.shutdown()

        let loginTransport = Transport90(), loginScheduler = Scheduler90()
        let loginModel = QuotaWindowModel(provider: loginTransport, refreshPolicy: .backgroundEvery60Seconds, scheduler: loginScheduler)
        loginModel.startBackgroundRefresh(); loginTransport.starts[0](.success(())); await drain()
        loginTransport.accounts[0](.success(["account": NSNull()])); await drain()
        loginModel.startClock(); loginModel.stopClock()
        check(loginModel.statusText == "需要登录" && loginTransport.starts.count == 1 && loginTransport.accounts.count == 1 && loginTransport.reads.isEmpty,
              "login-required presentation does not validate or reconnect")
        loginModel.shutdown()

        // A genuine account switch during a quota read clears old data, revalidates in
        // the same provider session, and rejects the old result after identity changes.
        let accountTransport = Transport90(), accountScheduler = Scheduler90()
        let accountModel = QuotaWindowModel(provider: accountTransport, now: { now }, refreshPolicy: .backgroundEvery60Seconds, scheduler: accountScheduler)
        accountModel.startBackgroundRefresh(); accountTransport.starts[0](.success(())); await drain()
        accountTransport.accounts[0](.success(account)); await drain()
        accountTransport.reads[0](.success(quota("account-old"))); await drain()
        let oldNotification = accountTransport.onNotification!
        accountModel.refresh(); check(accountTransport.reads.count == 2, "old account quota request starts")
        accountTransport.onNotification?("account/updated"); await drain()
        accountTransport.reads[1](.success(quota("account-old"))); await drain()
        check(accountModel.snapshot == nil && accountTransport.starts.count == 1 && accountTransport.accounts.count == 2,
              "account update discards in-flight quota and verifies without reconnecting")
        accountTransport.onNotification?("account/updated"); await drain()
        check(accountTransport.accounts.count == 2, "account notification during verification coalesces")
        accountTransport.accounts[1](.success(["account": ["type": "chatgpt", "email": "second@example.invalid"]])); await drain()
        check(accountTransport.reads.count == 3, "verified new identity proceeds to a new quota read")
        accountTransport.reads[2](.success(quota("account-new"))); await drain()
        oldNotification("account/updated")
        accountTransport.reads[1](.success(quota("account-old"))); await drain()
        accountModel.startClock(); accountModel.stopClock()
        check(accountModel.snapshot != nil && accountModel.statusText == "已更新" && accountTransport.starts.count == 1 && accountTransport.reads.count == 3,
              "late old identity callbacks cannot overwrite the new account snapshot")
        accountModel.shutdown()

        let firstChangeTransport = Transport90(), firstChangeScheduler = Scheduler90()
        let firstChangeModel = QuotaWindowModel(provider: firstChangeTransport, now: { now }, refreshPolicy: .backgroundEvery60Seconds, scheduler: firstChangeScheduler)
        firstChangeModel.startBackgroundRefresh(); firstChangeTransport.starts[0](.success(())); await drain()
        firstChangeTransport.accounts[0](.success(account)); await drain()
        firstChangeTransport.onNotification?("account/updated"); await drain()
        firstChangeTransport.reads[0](.success(quota("stale-first-account"))); await drain()
        check(firstChangeModel.snapshot == nil && firstChangeTransport.accounts.count == 2 && firstChangeTransport.reads.count == 1,
              "real account update during first quota read rejects old result even without an earlier notification echo")
        firstChangeTransport.accounts[1](.success(["account": ["type": "chatgpt", "email": "second@example.invalid"]])); await drain()
        firstChangeTransport.reads[1](.success(quota("current-first-account"))); await drain()
        check(firstChangeModel.snapshot != nil && firstChangeModel.statusText == "已更新" && firstChangeTransport.starts.count == 1,
              "post-event account verification publishes only the new quota without reconnecting")
        firstChangeModel.shutdown()

        guard CommandLine.arguments.count > 1 else { fatalError("FAIL: fake app-server path argument required") }
        let serverPath = CommandLine.arguments[1]
        for mode in ["before", "after", "batch"] {
            await exerciseStdioProvider(mode: mode, serverPath: serverPath)
        }
        await exerciseStdioProvider(mode: "account-switch", serverPath: serverPath, switchesAccount: true)
        await exerciseStdioProvider(mode: "null-id", serverPath: serverPath)

        // A previously displayed quota is cleared on account update. A post-event
        // account/read plus a fresh limits response can restore it even when accountId
        // is nullable; the email comparison is not used as proof of identity.
        let nullableTransport = Transport90(), nullableScheduler = Scheduler90()
        var nullableNow = Date(timeIntervalSince1970: 4_000_000)
        let nullableModel = QuotaWindowModel(provider: nullableTransport, now: { nullableNow }, refreshPolicy: .backgroundEvery60Seconds, scheduler: nullableScheduler)
        nullableModel.startBackgroundRefresh(); nullableTransport.starts[0](.success(())); await drain()
        nullableTransport.accounts[0](.success(account)); await drain()
        nullableTransport.reads[0](.success(quota("previous-account-id"))); await drain()
        let previousObservedAt = nullableModel.snapshot!.observedAt
        nullableNow.addTimeInterval(1)
        nullableTransport.onNotification?("account/updated"); await drain()
        check(nullableModel.snapshot == nil && nullableTransport.accounts.count == 2,
              "nullable account update clears existing quota and starts post-event verification")
        nullableTransport.accounts[1](.success(["account": ["type": "chatgpt", "email": "second@example.invalid"]])); await drain()
        nullableTransport.reads[1](.success(quota(nil))); await drain()
        check((nullableModel.snapshot?.observedAt ?? .distantPast) > previousObservedAt && nullableModel.statusText == "已更新",
              "fresh post-event quota restores display when accountId is null")
        nullableModel.shutdown()

        print("PASS #90 background model: startup, presentation isolation, 59/60s cadence, sparse notification, manual reset/retry, 60/120/300 backoff, Retry-After, sleep/wake, account generations and shutdown")
        print("PASS #90 real provider stdio replay: account/updated before, after and in one byte batch; stable polling; actual account switch rejects old quota; nullable accountId")
    }
}
