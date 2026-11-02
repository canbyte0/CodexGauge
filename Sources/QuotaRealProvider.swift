import Foundation

protocol QuotaTransport: AnyObject {
    var onNotification: ((String) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    var onEvent: ((String) -> Void)? { get set }
    func start(_ done: @escaping (Result<Void, Error>) -> Void)
    func account(_ done: @escaping (Result<[String: Any], Error>) -> Void)
    func limits(_ done: @escaping (Result<[String: Any], Error>) -> Void)
    func stop()
    func stopAndWait()
}

// Only the three documented read/initialization methods are sent. Responses stay in memory.
final class QuotaRealProvider: QuotaTransport {
    static let cli = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    private let queue = DispatchQueue(label: "local.quota.rpc")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var epoch = 0
    var onNotification: ((String) -> Void)?
    var onExit: (() -> Void)?
    var onEvent: ((String) -> Void)?
    enum Failure: Error { case untrusted, launch, timeout, protocolError, stopped, server(Date?) }
    #if QUOTA_TESTING
    private var testCommand: (String, [String])?
    init(testCommand: (String, [String])? = nil) { self.testCommand = testCommand }
    func testBreakInput() { queue.sync { try? input?.close() } }
    func testTerminateChild() { queue.sync { if let process, process.isRunning { process.terminate() } } }
    #endif

    func start(_ done: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.epoch += 1
            let current = self.epoch
            var executable = Self.cli
            var arguments = ["app-server", "--listen", "stdio://"]
            var requiresSignature = true
            #if QUOTA_TESTING
            if let command = self.testCommand { executable = command.0; arguments = command.1; requiresSignature = false }
            #endif
            if requiresSignature {
                let check = Process()
                check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                check.arguments = ["--verify", "--strict", "-R=anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"", Self.cli]
                check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
                do { try check.run(); check.waitUntilExit() } catch { done(.failure(Failure.untrusted)); return }
                guard check.terminationStatus == 0, current == self.epoch else { done(.failure(Failure.untrusted)); return }
            }
            let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
            p.terminationHandler = { [weak self] _ in self?.queue.async { [weak self] in self?.exited(current) } }
            do { try p.run() } catch { done(.failure(Failure.launch)); return }
            self.onEvent?("provider-start pid=\(p.processIdentifier)")
            self.process = p; self.input = stdin.fileHandleForWriting; self.output = stdout.fileHandleForReading; self.errors = stderr.fileHandleForReading
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async { [weak self] in self?.consume(data, epoch: current) }
            }
            // Drain stderr without retaining raw diagnostics or secrets.
            stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            self.send("initialize", params: ["clientInfo": ["name": "quota_window", "title": "Quota Window", "version": "0.2.0"], "capabilities": NSNull()], timeout: 15) { result in
                switch result {
                case .success:
                    if self.write(["method": "initialized", "params": [:]]) { done(.success(())) }
                    else { done(.failure(Failure.stopped)) }
                case .failure(let error): done(.failure(error))
                }
            }
        }
    }
    func account(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { self.send("account/read", params: ["refreshToken": false], timeout: 10, done: done) }
    }
    func limits(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { self.send("account/rateLimits/read", params: nil, timeout: 10, done: done) }
    }
    func stop() { queue.async { self.stopLocked() } }
    func stopAndWait() { queue.sync { self.stopLocked(wait: true) } }
    private func send(_ method: String, params: [String: Any]?, timeout: Double, done: @escaping (Result<[String: Any], Error>) -> Void) {
        guard process?.isRunning == true else { done(.failure(Failure.stopped)); return }
        let id = nextID; nextID += 1; pending[id] = done
        onEvent?("rpc-send method=\(method) id=\(id)")
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        write(message)
        let current = epoch
        queue.asyncAfter(deadline: .now() + timeout) {
            guard current == self.epoch, let callback = self.pending.removeValue(forKey: id) else { return }
            self.onEvent?("rpc-timeout id=\(id)")
            callback(.failure(Failure.timeout))
        }
    }
    @discardableResult
    private func write(_ object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let input else { transportFailed(); return false }
        do { try input.write(contentsOf: data + Data([10])); return true }
        catch { transportFailed(); return false }
    }
    private func consume(_ bytes: Data, epoch current: Int) {
        guard current == epoch, !bytes.isEmpty else { return }
        buffer.append(bytes)
        if buffer.count > 2_000_000 { transportFailed(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line), let message = value as? [String: Any] else { continue }
            if let method = message["method"] as? String {
                if let id = message["id"] { write(["id": id, "error": ["code": -32601, "message": "Unsupported request"]]); continue }
                if method == "account/updated" || method == "account/rateLimits/updated" { onNotification?(method) }
            } else if let id = message["id"] as? Int, let callback = pending.removeValue(forKey: id) {
                if let result = message["result"] as? [String: Any] { onEvent?("rpc-success id=\(id)"); callback(.success(result)) }
                else {
                    onEvent?("rpc-error id=\(id)")
                    var retry: Date?
                    if let error = message["error"] as? [String: Any], let data = error["data"] as? [String: Any] {
                        if let seconds = QuotaRealParser.number(data["retryAfterSeconds"] ?? data["retryAfter"]), seconds > 0, seconds < 604800 { retry = Date().addingTimeInterval(seconds) }
                        if let timestamp = QuotaRealParser.number(data["retryAt"]), timestamp > Date().timeIntervalSince1970, timestamp < 253402300800 { retry = max(retry ?? .distantPast, Date(timeIntervalSince1970: timestamp)) }
                    }
                    callback(.failure(Failure.server(retry)))
                }
            }
        }
    }
    private func transportFailed() { stopLocked(); onExit?() }
    private func exited(_ current: Int) {
        guard current == epoch else { return }
        stopLocked(); onExit?()
    }
    private func stopLocked(wait: Bool = false) {
        epoch += 1
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil; buffer.removeAll()
        let old = process; process = nil
        if let old { onEvent?("provider-stop pid=\(old.processIdentifier)") }
        if let old, old.isRunning {
            old.terminate()
            let pid = old.processIdentifier
            if wait {
                let until = Date().addingTimeInterval(2)
                while old.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
                if old.isRunning { kill(pid, SIGKILL) }
                old.waitUntilExit()
            } else { DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if old.isRunning { kill(pid, SIGKILL) } } }
        }
        let callbacks = pending.values; pending.removeAll()
        for callback in callbacks { callback(.failure(Failure.stopped)) }
    }
}
