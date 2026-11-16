import Foundation

// Callback and timeout may race. The lock protects the sole mutable callback;
// the winner invokes it outside the lock. Callers must accept execution on either thread.
public final class CompletionGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<Value, Error>) -> Void)?
    public init(_ completion: @escaping (Result<Value, Error>) -> Void) { self.completion = completion }
    public func complete(_ result: Result<Value, Error>) {
        lock.lock(); let target = completion; completion = nil; lock.unlock()
        target?(result)
    }
}
