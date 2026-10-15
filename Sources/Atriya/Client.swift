import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The running SDK instance behind the static `Atriya` API.
final class AtriyaClient: @unchecked Sendable {
    let apiKey: String
    let options: Atriya.Options
    let queue: EventQueue
    private let transport: EventTransport
    private let defaults: UserDefaults
    private let context: DeviceContext

    private let lock = NSLock()
    private var currentScreen: String?
    private var foregroundSince: Date?
    private var backgroundSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    #if canImport(MetricKit)
    private var crashReporter: AnyObject?
    #endif

    private enum Keys {
        static let installId = "io.atriya.installId"
        static let userId = "io.atriya.userId"
        static let optedOut = "io.atriya.optedOut"
        static let lastAppVersion = "io.atriya.lastAppVersion"
    }

    init(
        apiKey: String,
        baseURL: URL,
        options: Atriya.Options,
        context: DeviceContext,
        defaults: UserDefaults = .standard,
        transport: EventTransport? = nil,
        storeURL: URL? = AtriyaClient.defaultStoreURL()
    ) {
        self.apiKey = apiKey
        self.options = options
        self.context = context
        self.defaults = defaults
        let transport = transport ?? HTTPTransport(baseURL: baseURL)
        self.transport = transport
        self.queue = EventQueue(apiKey: apiKey, context: context, transport: transport, storeURL: storeURL)
    }

    static func defaultStoreURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "io.atriya.queue.json")
    }

    // MARK: - Identity

    /// Anonymous per-install ID (no IDFA, no tracking permission needed).
    /// Reinstalling the app starts a new one.
    var visitorId: String {
        if let id = defaults.string(forKey: Keys.installId) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Keys.installId)
        return id
    }

    var userId: String? {
        get { defaults.string(forKey: Keys.userId) }
        set { defaults.set(newValue, forKey: Keys.userId) }
    }

    var isOptedOut: Bool {
        get { defaults.bool(forKey: Keys.optedOut) }
        set { defaults.set(newValue, forKey: Keys.optedOut) }
    }

    // MARK: - Recording

    func record(
        type: String,
        name: String? = nil,
        value: Double? = nil,
        path: String? = nil,
        properties: [String: AtriyaValue]? = nil,
        at date: Date = Date()
    ) {
        guard !isOptedOut else { return }
        let screen: String? = lock.withLock {
            if type == "pageview", let path { currentScreen = path }
            return currentScreen
        }
        let event = QueuedEvent(
            type: type,
            name: name,
            value: value,
            path: path ?? screen,
            properties: properties?.isEmpty == true ? nil : properties,
            userId: userId,
            visitorId: visitorId,
            occurredAt: date
        )
        if queue.enqueue(event) >= options.flushAt {
            Task { await queue.flush() }
        }
    }

    func identify(userId: String, email: String?, name: String?, properties: [String: AtriyaValue]?) {
        guard !isOptedOut else { return }
        self.userId = userId
        let payload = IdentifyPayload(apiKey: apiKey, userId: userId, email: email, name: name, properties: properties)
        Task { [transport] in _ = await transport.identify(payload) }
    }

    // MARK: - Setup

    /// Restores events from an earlier launch, reports installs and updates,
    /// starts the flush timer and hooks into the app lifecycle and MetricKit.
    @MainActor
    func activate() {
        queue.restore()
        recordInstallOrUpdate()
        startTimer()
        if options.trackAppLifecycle { observeLifecycle() }
        #if canImport(MetricKit)
        if options.reportCrashes {
            crashReporter = CrashReporter.register { [weak self] reports in
                guard let self else { return }
                for report in reports {
                    self.record(type: "error", name: report.name, properties: report.properties, at: report.date)
                }
                Task { await self.queue.flush() }
            }
        }
        #endif
        Task { await queue.flush() }
    }

    private func recordInstallOrUpdate() {
        guard let version = context.appVersion else { return }
        let previous = defaults.string(forKey: Keys.lastAppVersion)
        if previous == nil {
            record(type: "app_install", properties: ["version": .string(version)])
        } else if previous != version {
            record(type: "app_update", properties: ["from": .string(previous ?? ""), "to": .string(version)])
        }
        defaults.set(version, forKey: Keys.lastAppVersion)
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + options.flushInterval, repeating: options.flushInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.queue.flush() }
        }
        timer.resume()
        self.timer = timer
    }

    // MARK: - App lifecycle

    @MainActor
    private func observeLifecycle() {
        #if os(iOS)
        let active = UIApplication.didBecomeActiveNotification
        let inactive = UIApplication.didEnterBackgroundNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        let inactive = NSApplication.didResignActiveNotification
        #endif
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: active, object: nil, queue: nil) { [weak self] _ in
            self?.didBecomeActive()
        })
        observers.append(center.addObserver(forName: inactive, object: nil, queue: nil) { [weak self] _ in
            self?.didEnterBackground()
        })
    }

    /// Short app switches (under a minute) continue the same foreground period.
    static let resumeGrace: TimeInterval = 60

    func didBecomeActive(now: Date = Date()) {
        let isNewOpen = lock.withLock { () -> Bool in
            defer {
                if foregroundSince == nil { foregroundSince = now }
                backgroundSince = nil
            }
            guard foregroundSince == nil else { return false }
            guard let backgroundSince else { return true }
            return now.timeIntervalSince(backgroundSince) >= Self.resumeGrace
        }
        if isNewOpen { record(type: "app_open", at: now) }
    }

    func didEnterBackground(now: Date = Date()) {
        let seconds = lock.withLock { () -> Int? in
            backgroundSince = now
            guard let since = foregroundSince else { return nil }
            foregroundSince = nil
            return Int(now.timeIntervalSince(since).rounded())
        }
        if let seconds {
            record(type: "app_background", properties: ["foregroundSeconds": .int(seconds)], at: now)
        }
        // Write first, so nothing is lost if iOS suspends the app mid-upload,
        // then send and rewrite the file with whatever is still pending.
        queue.persist()
        let queue = self.queue
        #if os(iOS)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Atriya: send analytics") { expired in
            guard !expired else {
                queue.persist()
                return
            }
            let done = DispatchSemaphore(value: 0)
            Task {
                await queue.flush()
                queue.persist()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 20)
        }
        #else
        // macOS doesn't suspend apps that lose focus.
        Task {
            await queue.flush()
            queue.persist()
        }
        #endif
    }
}
