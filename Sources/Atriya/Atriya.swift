import Foundation
import os

/// Atriya Analytics for iOS and macOS apps.
///
/// ```swift
/// Atriya.start(apiKey: "atr_pk_…", baseURL: URL(string: "https://intern.atriya.io")!)
/// Atriya.screen("Timer")                 // or `.atriyaScreen("Timer")` in SwiftUI
/// Atriya.track("timer_started", properties: ["project": "Website"])
/// ```
///
/// Screen views count like pageviews, so sessions, retention, funnels and
/// goals work for apps the same way as for websites. App opens and time in
/// the foreground are recorded automatically, crashes and hangs arrive via
/// MetricKit and show up as errors. No advertising ID is used, so no tracking
/// permission prompt is needed.
public enum Atriya {
    public static let sdkVersion = "0.1.2"

    public struct Options: Sendable {
        /// Records app opens and foreground time (`app_open`, `app_background`).
        public var trackAppLifecycle = true
        /// Reports crashes and hangs collected by MetricKit.
        public var reportCrashes = true
        /// Seconds between automatic uploads.
        public var flushInterval: TimeInterval = 15
        /// Uploads immediately once this many events are waiting.
        public var flushAt = 30

        public init() {}
    }

    private static let storage = OSAllocatedUnfairLock<AtriyaClient?>(initialState: nil)

    static var client: AtriyaClient? { storage.withLock { $0 } }

    /// Starts the SDK. Call once, as early as possible – e.g. in your `App`
    /// initializer or `application(_:didFinishLaunchingWithOptions:)`.
    /// Further calls are ignored.
    ///
    /// - Parameters:
    ///   - apiKey: The platform's key from the Atriya dashboard (`atr_pk_…`).
    ///   - baseURL: Your Atriya backend, e.g. `https://intern.atriya.io`.
    @MainActor
    public static func start(apiKey: String, baseURL: URL, options: Options = Options()) {
        let context = DeviceContext.current()
        let created = storage.withLock { state -> AtriyaClient? in
            guard state == nil else { return nil }
            let client = AtriyaClient(apiKey: apiKey, baseURL: baseURL, options: options, context: context)
            state = client
            return client
        }
        created?.activate()
    }

    /// Records a screen view. Screens appear like pages in the dashboard.
    public static func screen(_ name: String, properties: [String: AtriyaValue]? = nil) {
        client?.record(type: "pageview", path: screenPath(name), properties: properties)
    }

    /// Records a custom event, e.g. `track("timer_started")`.
    ///
    /// - Parameter value: Optional amount, e.g. a purchase price. Values of
    ///   custom events add up to the revenue figures in the dashboard.
    public static func track(_ name: String, value: Double? = nil, properties: [String: AtriyaValue]? = nil) {
        client?.record(type: "event", name: name, value: value, properties: properties)
    }

    /// Reports a handled error. It appears in the dashboard's error list,
    /// next to crashes.
    public static func track(error: any Error, properties: [String: AtriyaValue]? = nil) {
        var merged = properties ?? [:]
        merged["kind"] = "error"
        merged["errorType"] = .string(String(reflecting: type(of: error)))
        let message = String(String(describing: error).prefix(256))
        client?.record(type: "error", name: message, properties: merged)
    }

    /// Links this install to a user of your app. Later events carry the user
    /// ID, and the user shows up in the dashboard's user list.
    public static func identify(
        userId: String,
        email: String? = nil,
        name: String? = nil,
        properties: [String: AtriyaValue]? = nil
    ) {
        client?.identify(userId: userId, email: email, name: name, properties: properties)
    }

    /// Forgets the user set by `identify`, e.g. on logout. The anonymous
    /// install ID stays.
    public static func reset() {
        client?.userId = nil
    }

    /// Stops recording until `optIn()` is called. The choice is remembered
    /// across launches, also when made before `start(apiKey:baseURL:options:)`.
    public static func optOut() {
        setOptedOut(true)
    }

    public static func optIn() {
        setOptedOut(false)
    }

    public static var isOptedOut: Bool {
        client?.isOptedOut ?? AtriyaClient.isOptedOut(in: .standard)
    }

    private static func setOptedOut(_ optedOut: Bool) {
        if let client {
            client.isOptedOut = optedOut
        } else {
            AtriyaClient.setOptedOut(optedOut, in: .standard)
        }
    }

    /// Sends all waiting events now.
    public static func flush() async {
        await client?.queue.flush()
    }
}
