import Foundation

enum StreamingTextBatcher {
    static let defaultMinimumInterval: Duration = .milliseconds(50)

    static func snapshots(
        from source: AsyncThrowingStream<String, Error>,
        minimumInterval: Duration = defaultMinimumInterval
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                let clock = ContinuousClock()
                var accumulated = ""
                var pending = ""
                var lastEmission = clock.now

                do {
                    for try await chunk in source {
                        try Task.checkCancellation()
                        pending += chunk

                        let now = clock.now
                        let shouldEmitFirstChunk = accumulated.isEmpty && !pending.isEmpty
                        if shouldEmitFirstChunk || now - lastEmission >= minimumInterval {
                            accumulated += pending
                            pending.removeAll(keepingCapacity: true)
                            lastEmission = now
                            continuation.yield(accumulated)
                        }
                    }

                    if !pending.isEmpty {
                        accumulated += pending
                        continuation.yield(accumulated)
                    }
                    continuation.finish()
                } catch {
                    if error is CancellationError, Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }
}
