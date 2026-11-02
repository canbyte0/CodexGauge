import Darwin
import Dispatch

@MainActor
final class OverlayTerminationSignal {
    private var source: DispatchSourceSignal?
    private var previousAction: sigaction?
    private var terminationHandler: (() -> Void)?
    private var didInstall = false
    private var isShuttingDown = false
    private(set) var receivedTerminationSignal = false

    // SIGTERM 仅由 DispatchSource 接收；AppKit 退出逻辑在主线程执行。
    func install(onTermination: @escaping () -> Void) -> Bool {
        guard !didInstall else { return false }

        var ignoredAction = sigaction()
        sigemptyset(&ignoredAction.sa_mask)
        ignoredAction.sa_flags = 0
        ignoredAction.__sigaction_u.__sa_handler = SIG_IGN
        var previousAction = sigaction()
        guard sigaction(SIGTERM, &ignoredAction, &previousAction) == 0 else {
            return false
        }

        self.previousAction = previousAction
        terminationHandler = onTermination
        didInstall = true

        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown, !self.receivedTerminationSignal else { return }
                self.receivedTerminationSignal = true
                self.terminationHandler?()
            }
        }
        self.source = source
        source.resume()
        return true
    }

    func stopMonitoring() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        source?.setEventHandler {}
        source?.cancel()
        source = nil
        terminationHandler = nil
    }

    @discardableResult
    func restorePreviousSignalDisposition() -> Bool {
        stopMonitoring()
        guard var previousAction else { return true }
        let restored = sigaction(SIGTERM, &previousAction, nil) == 0
        self.previousAction = nil
        return restored
    }
}
