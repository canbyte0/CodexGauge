import AppKit
import Combine
import SwiftUI

enum QuotaWindowMode: Equatable { case summary, details }
enum QuotaRefreshPolicy { case whileVisible, backgroundEvery60Seconds }

// The scheduler only wakes the state machine; deadlines and request serialization live in the model.
@MainActor
protocol QuotaTickScheduling: AnyObject {
    func start(_ tick: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class QuotaRunLoopScheduler: QuotaTickScheduling {
    private var timer: Timer?
    func start(_ tick: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in Task { @MainActor in tick() } }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
}

@MainActor
final class QuotaWindowModel: NSObject, ObservableObject {
    @Published private(set) var mode: QuotaWindowMode = .summary
    @Published private(set) var clockNow = Date()
    @Published private(set) var contentSize = QuotaWindowLayout.summaryContentSize
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var status = "读取中"
    @Published private(set) var loading = false
    @Published private(set) var choices: [String] = []
    @Published private(set) var selection: String?
    private let provider: QuotaTransport
    private let now: () -> Date
    private let refreshPolicy: QuotaRefreshPolicy
    private let scheduler: QuotaTickScheduling
    private var backgroundStarted = false
    private var sleeping = false
    private var terminated = false
    private var requestReason = "visibility"
    private var visibleBeforeSleep = false
    private var visible = false
    private var connected = false
    private var accountReady = false
    private var checkingAccount = false
    private var failed = false
    private var session = 0
    private var request = 0
    private var nextRead = Date.distantPast
    private var failureCount = 0
    private var updatePending = false
    private var quotaInFlight = false
    private var observedAccountID: String?
    private var observedAccountEmail: String?
    private var accountUpdatePending = false
    private var accountUpdateRevalidationInFlight = false
    private var accountUpdateReverificationRequired = false
    private var accountReadNotificationSeen = false
    private var identityMustConfirm = false
    private var serviceRetryUntil = Date.distantPast
    var onEvent: ((String) -> Void)?

    private var active: Bool {
        !terminated && !sleeping && (refreshPolicy == .backgroundEvery60Seconds ? backgroundStarted : visible)
    }

    init(provider: QuotaTransport = QuotaRealProvider(), now: @escaping () -> Date = Date.init,
         refreshPolicy: QuotaRefreshPolicy = .whileVisible, scheduler: QuotaTickScheduling? = nil) {
        self.provider = provider; self.now = now; self.refreshPolicy = refreshPolicy
        self.scheduler = scheduler ?? QuotaRunLoopScheduler()
        super.init()
        clockNow = now()
        provider.onEvent = { [weak self] event in Task { @MainActor in self?.onEvent?(event) } }
        provider.onNotification = { [weak self] method in Task { @MainActor in self?.notification(method) } }
        provider.onExit = { [weak self] in Task { @MainActor in self?.connectionLost() } }
    }
    func showDetails(contentHeight: CGFloat) { contentSize = CGSize(width: QuotaWindowLayout.detailsContentSize.width, height: contentHeight); mode = .details }
    func showSummary() { contentSize = QuotaWindowLayout.summaryContentSize; mode = .summary }
    func startBackgroundRefresh() {
        guard refreshPolicy == .backgroundEvery60Seconds, !backgroundStarted, !terminated else { return }
        backgroundStarted = true
        if !sleeping { startScheduler(); requestRefresh(reason: "startup") }
    }
    private func startScheduler() { scheduler.start { [weak self] in self?.tick() } }
    func startClock() {
        guard !terminated else { return }
        visible = true
        clockNow = now()
        // In background mode, opening details is presentation only, including empty/error/stale data.
        guard refreshPolicy == .whileVisible, !sleeping else { return }
        startScheduler()
        // Automatic visibility recovery respects failure backoff; an explicit refresh may retry sooner.
        if failed && now() < nextRead { return }
        if !connected { connect() }
        else if !accountReady { verifyAccount(session) }
        else if snapshot == nil || now().timeIntervalSince(snapshot!.observedAt) >= 10 || failed { read() }
    }
    func stopClock() {
        visible = false
        if refreshPolicy == .whileVisible { scheduler.stop() }
    }
    func shutdown() {
        guard !terminated else { return }
        terminated = true; visible = false; backgroundStarted = false; scheduler.stop()
        session += 1; connected = false; loading = false; checkingAccount = false; quotaInFlight = false
        provider.onNotification = nil; provider.onExit = nil; provider.onEvent = nil
        provider.stopAndWait()
    }
    func sleep() {
        guard !terminated, !sleeping else { return }
        visibleBeforeSleep = visible; sleeping = true; scheduler.stop()
        if refreshPolicy == .whileVisible { visible = false }
    }
    func wake() {
        guard !terminated, sleeping else { return }
        sleeping = false
        if refreshPolicy == .backgroundEvery60Seconds {
            if backgroundStarted { startScheduler(); tick(reason: "wake") }
        } else if visibleBeforeSleep && NSApp?.isHidden != true { startClock() }
        visibleBeforeSleep = false
    }
    func select(_ id: String) {
        guard choices.contains(id), selection != id else { return }
        guard !loading, !terminated else { return }
        selection = id; session += 1; snapshot = nil; failed = false
        requestReason = "source-selection"
        bindCallbacks(session); if active && connected && accountReady { read() }
    }
    func refresh() { requestRefresh(reason: "manual") }
    private func requestRefresh(reason: String) {
        guard active, !loading, now() >= serviceRetryUntil else { return }
        requestReason = reason
        if connected { if accountReady { read() } else { verifyAccount(session) } } else { connect() }
    }
    private func tick(reason: String = "periodic") {
        guard active else { return }
        clockNow = now()
        if clockNow >= nextRead { requestRefresh(reason: reason) }
    }
    #if QUOTA_TESTING
    func testTick() { tick() }
    func testClockOnly() { clockNow = now() }
    #endif
    private func connect() {
        guard active && !loading && now() >= serviceRetryUntil else { return }
        session += 1; let generation = session
        bindCallbacks(generation)
        loading = true; status = "读取中"; snapshot = nil; failed = false; accountReady = false; checkingAccount = false
        provider.start { [weak self] result in Task { @MainActor in
            guard let self, generation == self.session else { return }
            switch result {
            case .failure(let error): self.loading = false; self.connected = false; self.provider.stop(); self.failure("无法连接", error: error)
            case .success: self.connected = true; self.loading = false; self.verifyAccount(generation)
            }
        } }
    }
    private func bindCallbacks(_ generation: Int) {
        provider.onNotification = { [weak self] method in Task { @MainActor in guard let self, self.session == generation else { return }; self.notification(method) } }
        provider.onExit = { [weak self] in Task { @MainActor in guard let self, self.session == generation else { return }; self.connectionLost() } }
    }
    private func verifyAccount(_ generation: Int) {
        guard active && connected && !loading && !checkingAccount && now() >= serviceRetryUntil else { return }
        checkingAccount = true; loading = true; accountReady = false
        accountReadNotificationSeen = false
        provider.account { [weak self] response in Task { @MainActor in
            guard let self, generation == self.session else { return }
            self.checkingAccount = false
            switch response {
            case .failure(let error):
                self.loading = false; self.accountUpdatePending = false
                self.accountUpdateRevalidationInFlight = false; self.accountUpdateReverificationRequired = false
                self.failure("无法连接", error: error)
            case .success(let object):
                guard let account = object["account"] as? [String: Any], let type = account["type"] as? String, type == "chatgpt" || type == "chatgptAuthTokens" else {
                    self.loading = false; self.snapshot = nil; self.observedAccountID = nil; self.observedAccountEmail = nil
                    self.selection = nil; self.choices = []; self.accountUpdatePending = false
                    self.accountUpdateRevalidationInFlight = false; self.accountUpdateReverificationRequired = false
                    self.identityMustConfirm = false
                    self.status = "需要登录"; self.nextRead = self.now().addingTimeInterval(60); return
                }
                if self.accountUpdatePending && !self.accountUpdateRevalidationInFlight {
                    // This account/read started before the update arrived. Run one new
                    // verification after the notification instead of restarting stdio.
                    self.loading = false; self.accountReady = false
                    self.startAccountUpdateRevalidation()
                    return
                }
                let email = (account["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let email, !email.isEmpty {
                    if let previous = self.observedAccountEmail, previous != email {
                        // Identity is compared in memory only. Never emit account fields to runtime logs.
                        self.snapshot = nil; self.observedAccountID = nil; self.selection = nil; self.choices = []
                        self.failed = false; self.failureCount = 0; self.serviceRetryUntil = .distantPast
                        self.nextRead = .distantPast; self.identityMustConfirm = true; self.session += 1
                        self.bindCallbacks(self.session)
                    }
                    self.observedAccountEmail = email
                }
                self.accountReady = true; self.loading = false; self.read()
            }
        } }
    }
    private func startAccountUpdateRevalidation() {
        guard !terminated else { return }
        // Invalidate all callbacks from the pre-update account generation immediately,
        // while keeping the already-running CLI transport alive.
        session += 1; bindCallbacks(session)
        accountUpdateRevalidationInFlight = true
        accountUpdateReverificationRequired = false
        requestReason = "account-change"
        accountReady = false
        verifyAccount(session)
    }
    private func read() {
        guard active, connected, accountReady, !loading, now() >= serviceRetryUntil else { return }
        loading = true; quotaInFlight = true; status = "读取中"; request += 1
        onEvent?("quota-read reason=\(requestReason) at=\(Int(now().timeIntervalSince1970))")
        let generation = session, requestID = request, selected = selection
        provider.limits { [weak self] response in Task { @MainActor in
            guard let self, generation == self.session, requestID == self.request else { return }
            self.loading = false; self.quotaInFlight = false
            if self.accountUpdatePending && (!self.accountUpdateRevalidationInFlight || self.accountUpdateReverificationRequired) {
                // A notification arrived after the account/read used by this quota request.
                // Discard the response, then verify on the same CLI session exactly once.
                self.startAccountUpdateRevalidation()
                return
            }
            switch response {
            case .failure(let error):
                self.accountUpdatePending = false; self.accountUpdateRevalidationInFlight = false
                self.accountUpdateReverificationRequired = false
                self.failure("无法连接", error: error)
            case .success(let object):
                let accountID = (object["accountId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if self.accountUpdatePending && self.accountUpdateRevalidationInFlight {
                    if let accountID {
                        if let previous = self.observedAccountID, previous != accountID {
                            // This response follows an account/read performed after the update.
                            // Invalidate older callbacks, then accept only this new account's read.
                            self.session += 1; self.selection = nil; self.choices = []
                            self.bindCallbacks(self.session)
                        }
                        self.observedAccountID = accountID
                        self.identityMustConfirm = false
                    } else if self.identityMustConfirm {
                        if self.accountUpdatePending && !self.accountUpdateReverificationRequired {
                            // account/read and this limits read both began after the update.
                            // A nullable accountId is acceptable for this fresh chain because
                            // all pre-update data and callbacks have already been invalidated.
                            self.identityMustConfirm = false
                        } else {
                            self.accountUpdatePending = false; self.accountUpdateRevalidationInFlight = false
                            self.accountUpdateReverificationRequired = false
                            self.status = "账号待确认"; self.nextRead = self.now().addingTimeInterval(60)
                            self.onEvent?("account-update handling=unverified")
                            return
                        }
                    }
                    // End the old request generation only after the post-update read
                    // has been checked; this also rejects any delayed old notifications.
                    self.session += 1; self.bindCallbacks(self.session)
                    self.accountUpdatePending = false; self.accountUpdateRevalidationInFlight = false
                    self.accountUpdateReverificationRequired = false
                } else if self.identityMustConfirm {
                    guard let accountID else {
                        self.status = "账号待确认"; self.nextRead = self.now().addingTimeInterval(60)
                        self.onEvent?("account-update handling=unverified")
                        return
                    }
                    if let previous = self.observedAccountID, previous != accountID {
                        self.accountUpdatePending = true
                        self.startAccountUpdateRevalidation()
                        return
                    }
                    self.observedAccountID = accountID; self.identityMustConfirm = false
                } else if let accountID {
                    if let previous = self.observedAccountID, previous != accountID {
                        self.session += 1; self.snapshot = nil; self.loading = false; self.connected = false
                        self.observedAccountID = nil; self.observedAccountEmail = nil; self.selection = nil; self.choices = []
                        self.provider.stop(); self.connect(); return
                    }
                    self.observedAccountID = accountID
                }
                switch QuotaRealParser.parse(object, selection: selected, now: self.now()) {
                case .invalid: self.snapshot = nil; self.failure("协议不兼容")
                case .choose(let keys): self.snapshot = nil; self.choices = keys; self.status = "请选择额度来源"; self.nextRead = self.now().addingTimeInterval(60)
                case .snapshot(let result, let keys):
                    self.snapshot = result; self.choices = keys; self.failed = false; self.failureCount = 0
                    self.serviceRetryUntil = .distantPast; self.status = "已更新"; self.nextRead = self.now().addingTimeInterval(60)
                    self.onEvent?("snapshot bucket=\(result.bucketID == "codex" ? "codex" : "other") five=\(QuotaRealParser.percent(result.fiveHour.remaining)) week=\(QuotaRealParser.percent(result.week.remaining)) resets=\(QuotaRealParser.count(result.resets))")
                }
            }
            if self.updatePending {
                self.updatePending = false
                if self.refreshPolicy == .whileVisible && !self.failed { self.nextRead = min(self.nextRead, self.now().addingTimeInterval(10)) }
            }
            self.accountReadNotificationSeen = false
        } }
    }
    private func failure(_ message: String, error: Error? = nil) {
        if let error = error as? QuotaRealProvider.Failure, case .server(let until) = error, let until { serviceRetryUntil = max(serviceRetryUntil, until) }
        failed = true; failureCount += 1
        status = snapshot == nil ? message : "上次数据 · 刷新失败"
        nextRead = max(serviceRetryUntil, now().addingTimeInterval([60.0, 120.0, 300.0][min(failureCount - 1, 2)]))
    }
    private func notification(_ method: String) {
        guard !terminated else { return }
        if method == "account/updated" {
            guard connected else { return }
            let phase = checkingAccount ? "account-read" : quotaInFlight ? "quota-read" : "idle"
            let hadSnapshot = snapshot != nil
            snapshot = nil; identityMustConfirm = identityMustConfirm || hadSnapshot || observedAccountID != nil
            requestReason = "account-change"
            if accountUpdateRevalidationInFlight && !accountReadNotificationSeen {
                // One notification can accompany this specific account/read. The old
                // snapshot remains cleared, and the following limits response must
                // still match the previously observed account ID before it is shown.
                accountReadNotificationSeen = true
                onEvent?("account-update handling=coalesced-account-read phase=\(phase)")
                return
            }
            if accountUpdatePending {
                if accountUpdateRevalidationInFlight { accountUpdateReverificationRequired = true }
                onEvent?("account-update handling=coalesced-pending phase=\(phase)")
            } else {
                accountUpdatePending = true
                onEvent?("account-update handling=verify phase=\(phase)")
            }
            if checkingAccount || quotaInFlight || loading { return }
            if active { startAccountUpdateRevalidation() }
        } else if method == "account/rateLimits/updated" {
            // The generated protocol says this update is sparse. Fetch a complete batch.
            // Background mode already fetches the full batch at its next 60-second deadline.
            guard refreshPolicy == .whileVisible else { return }
            if loading { updatePending = true } else if active && !failed { nextRead = min(nextRead, now().addingTimeInterval(10)) }
        }
    }
    private func connectionLost() {
        guard connected else { return }
        session += 1; connected = false; loading = false; checkingAccount = false; quotaInFlight = false; snapshot = nil
        accountReadNotificationSeen = false; accountUpdatePending = false
        accountUpdateRevalidationInFlight = false; accountUpdateReverificationRequired = false
        // A failed RPC and the transport exit can report the same underlying failure.
        if failed { status = "无法连接" } else { failure("无法连接") }
    }
    var stale: Bool { guard let s = snapshot else { return true }; return failed || clockNow.timeIntervalSince(s.observedAt) > 120 }
    func expired(_ value: QuotaWindowValue) -> Bool { stale || (value.reset.map { $0 <= clockNow } ?? false) }
    func summary(_ field: QuotaField<Double>, window: QuotaWindowValue) -> String { expired(window) ? "—" : QuotaRealParser.percent(field) }
    var resetSummary: String { guard let s = snapshot, !stale else { return "—" }; return QuotaRealParser.count(s.resets) }
    var statusText: String {
        if snapshot != nil, stale { return failed ? "上次数据 · 刷新失败" : "已过期" }
        if let s = snapshot, (s.fiveHour.reset.map { $0 <= clockNow } ?? false) || (s.week.reset.map { $0 <= clockNow } ?? false) { return "等待更新" }
        return status
    }
    var summaryStatusText: String {
        switch statusText {
        case "上次数据 · 刷新失败": return "刷新失败"
        case "需要登录": return "需登录"
        case "请选择额度来源": return "选来源"
        case "协议不兼容": return "协议异常"
        default: return statusText
        }
    }
}
