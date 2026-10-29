import Foundation
import Testing
@testable import Atriya

extension DeviceContext {
    static let test = DeviceContext(
        os: "iOS",
        osVersion: "18.6",
        deviceType: "mobile",
        deviceModel: "iPhone15,3",
        appVersion: "1.4 (12)",
        sdk: "atriya-swift/test"
    )
}

final class MockTransport: EventTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [DeliveryResult]
    private let fallback: DeliveryResult
    private var sent: [WireBatch] = []

    init(results: [DeliveryResult] = [], fallback: DeliveryResult = .delivered) {
        self.results = results
        self.fallback = fallback
    }

    var batchSizes: [Int] { lock.withLock { sent.map(\.events.count) } }

    var batches: [WireBatch] { lock.withLock { sent } }

    func send(_ batch: WireBatch) async -> DeliveryResult {
        lock.withLock {
            sent.append(batch)
            return results.isEmpty ? fallback : results.removeFirst()
        }
    }

    func identify(_ payload: IdentifyPayload) async -> DeliveryResult { .delivered }
}

private func event(_ name: String, at date: Date = Date()) -> QueuedEvent {
    QueuedEvent(type: "event", name: name, visitorId: "v", occurredAt: date)
}

@Suite struct WireFormatTests {
    @Test func offsetsAreMeasuredFromSendTimeOldestFirst() {
        let sentAt = Date(timeIntervalSince1970: 1_000)
        let batch = WireBatch(
            apiKey: "k",
            context: .test,
            events: [
                QueuedEvent(type: "pageview", path: "/Timer", visitorId: "v", occurredAt: sentAt - 1.5),
                event("late", at: sentAt - 0.25),
                QueuedEvent(type: "pageview", path: "/Start", visitorId: "v", occurredAt: sentAt - 3),
            ],
            sentAt: sentAt
        )
        #expect(batch.events.map(\.offsetMs) == [3000, 1500, 250])
        #expect(batch.events.first?.path == "/Start")
    }

    @Test func encodesTheIngestShape() throws {
        let sentAt = Date()
        var queued = event("timer_started", at: sentAt)
        queued.properties = ["project": "Website", "billable": true, "minutes": 25]
        let batch = WireBatch(apiKey: "k", context: .test, events: [queued], sentAt: sentAt)

        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any]
        )
        #expect(json["apiKey"] as? String == "k")
        #expect(json["anonymous"] == nil)
        let context = try #require(json["context"] as? [String: Any])
        #expect(context["os"] as? String == "iOS")
        #expect(context["appVersion"] as? String == "1.4 (12)")
        let sent = try #require((json["events"] as? [[String: Any]])?.first)
        #expect(sent["offsetMs"] as? Int == 0)
        #expect(sent["occurredAt"] == nil)
        let properties = try #require(sent["properties"] as? [String: Any])
        #expect(properties["billable"] as? Bool == true)
        #expect(properties["minutes"] as? Int == 25)
    }

    /// The Mac branch also describes Mac Catalyst apps, which reported "iPadOS"
    /// and "arm64" before.
    @MainActor
    @Test func describesTheMacByItsModel() {
        let context = DeviceContext.current()
        #expect(context.os == "macOS")
        #expect(context.deviceType == "desktop")
        #expect(!context.deviceModel.isEmpty)
        #expect(!["arm64", "x86_64"].contains(context.deviceModel))
    }

    @Test func screenNamesBecomePaths() {
        #expect(screenPath("Timer") == "/Timer")
        #expect(screenPath(" /Settings ") == "/Settings")
    }
}

@Suite struct EventQueueTests {
    @Test func sendsInBatchesOfAtMostOneHundred() async {
        let transport = MockTransport()
        let queue = EventQueue(apiKey: "k", context: .test, transport: transport, storeURL: nil)
        for index in 0..<250 { queue.enqueue(event("e\(index)")) }
        await queue.flush()
        #expect(transport.batchSizes == [100, 100, 50])
        #expect(queue.count == 0)
    }

    @Test func keepsEventsWhileTheBackendIsUnreachable() async {
        let transport = MockTransport(results: [.retryLater])
        let queue = EventQueue(apiKey: "k", context: .test, transport: transport, storeURL: nil)
        for index in 0..<3 { queue.enqueue(event("e\(index)")) }
        await queue.flush()
        #expect(queue.count == 3)
        await queue.flush()
        #expect(queue.count == 0)
    }

    @Test func dropsBatchesTheBackendRejects() async {
        let queue = EventQueue(
            apiKey: "k",
            context: .test,
            transport: MockTransport(results: [.rejected]),
            storeURL: nil
        )
        queue.enqueue(event("invalid"))
        await queue.flush()
        #expect(queue.count == 0)
    }

    @Test func survivesARestart() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "atriya-\(UUID()).json")
        let before = EventQueue(apiKey: "k", context: .test, transport: MockTransport(), storeURL: url)
        before.enqueue(event("a"))
        before.enqueue(event("b"))
        before.persist()

        let after = EventQueue(apiKey: "k", context: .test, transport: MockTransport(), storeURL: url)
        after.restore()
        #expect(after.pending.map(\.name) == ["a", "b"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct LifecycleTests {
    private func client(defaults: UserDefaults, context: DeviceContext = .test) -> AtriyaClient {
        var options = Atriya.Options()
        options.trackAppLifecycle = false
        options.reportCrashes = false
        return AtriyaClient(
            apiKey: "k",
            baseURL: URL(string: "http://localhost")!,
            options: options,
            context: context,
            defaults: defaults,
            transport: MockTransport(fallback: .retryLater),
            storeURL: nil
        )
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "atriya-tests-\(UUID())")!
    }

    @Test func recordsOpensAndForegroundTime() {
        let atriya = client(defaults: freshDefaults())
        let start = Date()
        atriya.didBecomeActive(now: start)
        atriya.didEnterBackground(now: start + 42)
        // A quick app switch continues the same foreground period …
        atriya.didBecomeActive(now: start + 50)
        atriya.didEnterBackground(now: start + 60)
        // … a longer break counts as a new open.
        atriya.didBecomeActive(now: start + 180)

        let types = atriya.queue.pending.map(\.type)
        #expect(types == ["app_open", "app_background", "app_background", "app_open"])
        #expect(atriya.queue.pending[1].properties?["foregroundSeconds"] == 42)
    }

    @Test func eventsCarryTheCurrentScreenAndUser() {
        let atriya = client(defaults: freshDefaults())
        atriya.record(type: "pageview", path: "/Timer")
        atriya.userId = "u-1"
        atriya.record(type: "event", name: "timer_started")

        let last = atriya.queue.pending.last
        #expect(last?.path == "/Timer")
        #expect(last?.userId == "u-1")
        #expect(last?.visitorId == atriya.queue.pending.first?.visitorId)
    }

    @Test func optOutStopsRecording() {
        let atriya = client(defaults: freshDefaults())
        atriya.isOptedOut = true
        atriya.record(type: "event", name: "ignored")
        #expect(atriya.queue.count == 0)
    }

    @MainActor
    @Test func optOutHoldsOnTheNextLaunch() {
        let defaults = freshDefaults()
        // As `Atriya.optOut()` does before `start`: no client yet.
        AtriyaClient.setOptedOut(true, in: defaults)
        let nextLaunch = client(defaults: defaults)
        #expect(nextLaunch.isOptedOut)
        nextLaunch.activate()
        nextLaunch.record(type: "event", name: "ignored")
        #expect(nextLaunch.queue.count == 0, "no app_install, no events")

        nextLaunch.isOptedOut = false
        #expect(client(defaults: defaults).isOptedOut == false)
    }

    @MainActor
    @Test func reportsInstallsAndUpdates() {
        let defaults = freshDefaults()
        let first = client(defaults: defaults)
        first.activate()
        #expect(first.queue.pending.map(\.type) == ["app_install"])

        var updated = DeviceContext.test
        updated.appVersion = "1.5 (13)"
        let second = client(defaults: defaults, context: updated)
        second.activate()
        #expect(second.queue.pending.map(\.type) == ["app_update"])
        #expect(second.queue.pending.first?.properties?["from"] == "1.4 (12)")
    }
}

@Suite struct AnonymousModeTests {
    private func client(
        defaults: UserDefaults,
        storeURL: URL?,
        anonymous: Bool = true,
        transport: MockTransport = MockTransport(fallback: .retryLater)
    ) -> AtriyaClient {
        var options = Atriya.Options()
        options.trackAppLifecycle = false
        options.reportCrashes = false
        options.anonymous = anonymous
        return AtriyaClient(
            apiKey: "k",
            baseURL: URL(string: "http://localhost")!,
            options: options,
            context: .test,
            defaults: defaults,
            transport: transport,
            storeURL: storeURL
        )
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "atriya-tests-\(UUID())")!
    }

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "atriya-\(UUID()).json")
    }

    private func storedKeys(_ defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("io.atriya.") }.sorted()
    }

    @MainActor
    @Test func keepsNothingOnTheDevice() {
        let defaults = freshDefaults()
        let url = storeURL()
        let atriya = client(defaults: defaults, storeURL: url)
        atriya.activate()
        let start = Date()
        atriya.didBecomeActive(now: start)
        atriya.record(type: "pageview", path: "/Timer")
        atriya.identify(userId: "u-1", email: nil, name: nil, properties: nil)
        atriya.userId = "u-1"
        atriya.didEnterBackground(now: start + 30)
        atriya.queue.persist()

        let pending = atriya.queue.pending
        #expect(pending.map(\.type) == ["app_open", "pageview", "app_background"], "no app_install")
        #expect(pending.allSatisfy { $0.visitorId == nil && $0.userId == nil })
        #expect(storedKeys(defaults).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test func forgetsWhatAnEarlierVersionStored() {
        let defaults = freshDefaults()
        let url = storeURL()
        // A launch without anonymous mode: install ID, user, app version and
        // an event waiting on disk.
        let before = client(defaults: defaults, storeURL: url, anonymous: false)
        before.activate()
        before.userId = "u-1"
        before.queue.persist()
        #expect(storedKeys(defaults) == ["io.atriya.installId", "io.atriya.lastAppVersion", "io.atriya.userId"])
        #expect(FileManager.default.fileExists(atPath: url.path))

        let after = client(defaults: defaults, storeURL: url)
        after.activate()
        #expect(after.queue.count == 0, "the old events carry the install ID")
        #expect(storedKeys(defaults).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theOptOutIsTheOnlyThingRemembered() {
        let defaults = freshDefaults()
        let atriya = client(defaults: defaults, storeURL: nil)
        atriya.isOptedOut = true
        atriya.record(type: "event", name: "ignored")
        #expect(atriya.queue.count == 0)
        #expect(storedKeys(defaults) == ["io.atriya.optedOut"])
    }

    @Test func batchesSayTheyAreAnonymousAndCarryNoIDs() async throws {
        let transport = MockTransport()
        let atriya = client(defaults: freshDefaults(), storeURL: nil, transport: transport)
        atriya.record(type: "event", name: "timer_started")
        await atriya.queue.flush()

        let batch = try #require(transport.batches.first)
        #expect(batch.anonymous == true)
        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any]
        )
        #expect(json["anonymous"] as? Bool == true)
        let sent = try #require((json["events"] as? [[String: Any]])?.first)
        #expect(sent["name"] as? String == "timer_started")
        #expect(sent["visitorId"] == nil)
        #expect(sent["userId"] == nil)
    }
}

@Suite struct DiagnosticParserTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func turnsACrashIntoAnErrorReport() throws {
        let report = try #require(DiagnosticParser.crash(from: fixture("crash")))
        #expect(report.name == "Crash: EXC_BAD_ACCESS (SIGSEGV)")
        #expect(report.properties["kind"] == "crash")
        #expect(report.properties["appVersion"] == "1.4")
        #expect(report.properties["frames"] == "SimpleTime +0x1a2b3c\nSwiftUI +0x181cd\nUIKitCore +0x1000")
        #expect(report.properties["binaryImages"] == """
            9E8D8DE8-794B-3F11-9C1C-4D3C1B2F8E10 SimpleTime
            B5F3A6C2-6C1D-3D8E-9F4B-2A7E5C1D9B03 SwiftUI
            0C7A1E55-4B8F-3E62-A9D1-7F3B2C4E6A18 UIKitCore
            """)
    }

    /// Reports from devices carry the load address in offsetIntoBinaryTextSegment.
    @Test func takesTheOffsetFromTheAddressWhenMetricKitSendsTheLoadAddress() throws {
        let report = try #require(DiagnosticParser.crash(from: fixture("crash-device")))
        #expect(report.properties["frames"] == "Atriya +0x4498\nAtriya +0x9a10\nSwiftUICore +0x2c4f0")
        #expect(report.properties["binaryImages"] == """
            269D8A8F-4BCC-3E30-AA27-368ED680E51E Atriya
            3F1C7A0E-2B4D-3C5E-9A8B-7D6E5F4A3B2C SwiftUICore
            """)
    }

    @Test func turnsAHangIntoAnErrorReport() throws {
        let report = try #require(DiagnosticParser.hang(from: fixture("hang")))
        #expect(report.name == "Hang: 2.53 sec")
        #expect(report.properties["kind"] == "hang")
        #expect(report.properties["frames"] == "SimpleTime +0x800")
    }

    @Test func ignoresUnreadableDiagnostics() {
        #expect(DiagnosticParser.crash(from: Data("{}".utf8)) == nil)
        #expect(DiagnosticParser.hang(from: Data("not json".utf8)) == nil)
    }
}
