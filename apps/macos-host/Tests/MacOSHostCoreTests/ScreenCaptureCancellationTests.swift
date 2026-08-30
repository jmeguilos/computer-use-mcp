import Foundation
import Testing
@testable import MacOSHostCore

private enum CaptureCallbackTestError: Error {
    case lateFailure
}

private final class CaptureCallbackProbe<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Result<Value, Error>) -> Void)?

    func install(_ callback: @escaping @Sendable (Result<Value, Error>) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func isInstalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        let callback = callback
        lock.unlock()
        callback?(result)
    }
}

@Suite("ScreenCapture callback cancellation")
struct ScreenCaptureCancellationTests {
    @Test func synchronousDuplicateCallbackResumesOnlyOnce() async throws {
        let value = try await ScreenCaptureCallbackBridge<Int>.awaitValue(
            deadline: Date().addingTimeInterval(5)
        ) { resolve in
            resolve(.success(42))
            resolve(.failure(CaptureCallbackTestError.lateFailure))
        }

        #expect(value == 42)
    }

    @Test func cancellationCompletesPromptlyAndIgnoresLateCallbacks() async throws {
        let probe = CaptureCallbackProbe<Int>()
        let task = Task {
            try await ScreenCaptureCallbackBridge<Int>.awaitValue(
                deadline: Date().addingTimeInterval(5)
            ) { resolve in
                probe.install(resolve)
            }
        }

        #expect(await waitUntilInstalled(probe))
        task.cancel()
        switch await task.result {
        case .success:
            Issue.record("A canceled callback wait unexpectedly succeeded")
        case .failure(let error):
            #expect(error is CancellationError)
        }

        // These model a framework callback racing after cancellation and an
        // erroneous duplicate callback. Neither may resume the continuation.
        probe.resolve(.success(7))
        probe.resolve(.failure(CaptureCallbackTestError.lateFailure))
    }

    @Test func deadlineCompletesStalledCallbackAndIgnoresLateResult() async throws {
        let probe = CaptureCallbackProbe<Int>()
        let task = Task {
            try await ScreenCaptureCallbackBridge<Int>.awaitValue(
                deadline: Date().addingTimeInterval(0.02)
            ) { resolve in
                probe.install(resolve)
            }
        }

        #expect(await waitUntilInstalled(probe))
        switch await task.result {
        case .success:
            Issue.record("A callback wait unexpectedly outlived its deadline")
        case .failure(let error):
            #expect((error as? CaptureError) == .captureTimedOut)
            #expect(WireErrorMapping.map(error).code == "ACTION_TIMEOUT")
        }

        probe.resolve(.success(7))
    }

    private func waitUntilInstalled<Value>(_ probe: CaptureCallbackProbe<Value>) async -> Bool {
        for _ in 0..<200 {
            if probe.isInstalled() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}
