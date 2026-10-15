import Foundation

/// An event waiting to be sent. Persisted as-is when the app goes to the
/// background, so it survives termination and is sent on the next launch.
struct QueuedEvent: Codable, Sendable, Equatable {
    var type: String
    var name: String?
    var value: Double?
    var path: String?
    var properties: [String: AtriyaValue]?
    var userId: String?
    var visitorId: String
    /// When the event happened on this device. Never sent directly: the batch
    /// carries `offsetMs` instead, so a wrong device clock doesn't matter.
    var occurredAt: Date
}

/// What the backend receives per event (`POST /api/ingest/v1/events`).
struct WireEvent: Encodable, Equatable, Sendable {
    var type: String
    var name: String?
    var value: Double?
    var path: String?
    var properties: [String: AtriyaValue]?
    var userId: String?
    var visitorId: String
    var offsetMs: Int
}

struct WireBatch: Encodable, Sendable {
    var apiKey: String
    var context: DeviceContext
    var events: [WireEvent]

    init(apiKey: String, context: DeviceContext, events: [QueuedEvent], sentAt: Date) {
        self.apiKey = apiKey
        self.context = context
        self.events = events
            .sorted { $0.occurredAt < $1.occurredAt }
            .map { event in
                WireEvent(
                    type: event.type,
                    name: event.name,
                    value: event.value,
                    path: event.path,
                    properties: event.properties,
                    userId: event.userId,
                    visitorId: event.visitorId,
                    offsetMs: max(0, Int((sentAt.timeIntervalSince(event.occurredAt) * 1000).rounded()))
                )
            }
    }
}

/// Screen names become paths ("Timer" → "/Timer"), so screens show up like
/// pages in the dashboard: top screens, entry/exit, funnels and goals.
func screenPath(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
}
