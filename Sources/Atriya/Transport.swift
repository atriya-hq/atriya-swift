import Foundation

enum DeliveryResult: Sendable, Equatable {
    case delivered
    /// Network error, rate limit or server error: keep the events and try later.
    case retryLater
    /// The backend refused the payload (bad key, invalid data). Retrying the
    /// same payload won't help, so it is dropped.
    case rejected
}

struct IdentifyPayload: Encodable, Sendable {
    var apiKey: String
    var userId: String
    var email: String?
    var name: String?
    var properties: [String: AtriyaValue]?
}

protocol EventTransport: Sendable {
    func send(_ batch: WireBatch) async -> DeliveryResult
    func identify(_ payload: IdentifyPayload) async -> DeliveryResult
}

struct HTTPTransport: EventTransport {
    let baseURL: URL
    var session: URLSession = .shared

    func send(_ batch: WireBatch) async -> DeliveryResult {
        await post("api/ingest/v1/events", body: batch)
    }

    func identify(_ payload: IdentifyPayload) async -> DeliveryResult {
        await post("api/ingest/v1/identify", body: payload)
    }

    private func post(_ path: String, body: some Encodable) async -> DeliveryResult {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (_, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200..<300: return .delivered
            case 429, 500...: return .retryLater
            default: return .rejected
            }
        } catch {
            return .retryLater
        }
    }
}
