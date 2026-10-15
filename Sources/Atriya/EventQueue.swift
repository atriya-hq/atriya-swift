import Foundation
import os

private let log = Logger(subsystem: "io.atriya.sdk", category: "queue")

/// Buffers events in memory and sends them in batches. When the app goes to
/// the background the buffer is written to disk, so events survive
/// termination and go out on the next launch.
final class EventQueue: @unchecked Sendable {
    /// The backend accepts at most 100 events per request.
    static let batchLimit = 100
    /// Upper bound while the backend is unreachable; the oldest events go first.
    static let maxStored = 1000

    private let lock = NSLock()
    private var events: [Entry] = []
    private var isFlushing = false

    private let apiKey: String
    private let context: DeviceContext
    private let transport: EventTransport
    private let storeURL: URL?
    private let now: @Sendable () -> Date

    private struct Entry: Codable {
        var id = UUID()
        var event: QueuedEvent
    }

    init(
        apiKey: String,
        context: DeviceContext,
        transport: EventTransport,
        storeURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKey = apiKey
        self.context = context
        self.transport = transport
        self.storeURL = storeURL
        self.now = now
    }

    var count: Int { lock.withLock { events.count } }

    var pending: [QueuedEvent] { lock.withLock { events.map(\.event) } }

    /// Adds an event and returns the new queue length.
    @discardableResult
    func enqueue(_ event: QueuedEvent) -> Int {
        lock.withLock {
            events.append(Entry(event: event))
            if events.count > Self.maxStored {
                events.removeFirst(events.count - Self.maxStored)
            }
            return events.count
        }
    }

    /// Sends everything queued, batch by batch. Stops early when the backend
    /// can't be reached; the remaining events stay queued. Concurrent calls
    /// return immediately while a flush is running.
    func flush() async {
        let started = lock.withLock { () -> Bool in
            if isFlushing { return false }
            isFlushing = true
            return true
        }
        guard started else { return }
        defer { lock.withLock { isFlushing = false } }

        while true {
            let batch = lock.withLock { Array(events.prefix(Self.batchLimit)) }
            guard !batch.isEmpty else { return }
            let body = WireBatch(apiKey: apiKey, context: context, events: batch.map(\.event), sentAt: now())
            let result = await transport.send(body)
            if result == .retryLater { return }
            if result == .rejected {
                log.error("Atriya rejected a batch of \(batch.count) events; check the API key.")
            }
            let sent = Set(batch.map(\.id))
            lock.withLock { events.removeAll { sent.contains($0.id) } }
        }
    }

    /// Writes the queue to disk, or removes the file when nothing is pending.
    func persist() {
        guard let storeURL else { return }
        let snapshot = lock.withLock { events }
        do {
            if snapshot.isEmpty {
                if FileManager.default.fileExists(atPath: storeURL.path) {
                    try FileManager.default.removeItem(at: storeURL)
                }
            } else {
                try JSONEncoder().encode(snapshot).write(to: storeURL, options: .atomic)
            }
        } catch {
            log.error("Atriya couldn't persist its queue: \(error.localizedDescription)")
        }
    }

    /// Loads events persisted by an earlier launch and deletes the file.
    func restore() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL) else { return }
        try? FileManager.default.removeItem(at: storeURL)
        guard let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        lock.withLock {
            events.insert(contentsOf: saved, at: 0)
            if events.count > Self.maxStored {
                events.removeFirst(events.count - Self.maxStored)
            }
        }
    }
}
