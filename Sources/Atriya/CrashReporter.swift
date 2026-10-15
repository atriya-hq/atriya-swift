#if canImport(MetricKit)
import Foundation
import MetricKit

/// Receives crash and hang diagnostics from MetricKit. iOS delivers them on
/// the next launch after a crash (hangs at most once a day), with the call
/// stack of the affected thread.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    struct Report: Sendable {
        var name: String
        var properties: [String: AtriyaValue]
        var date: Date
    }

    private let onReports: @Sendable ([Report]) -> Void

    private init(onReports: @escaping @Sendable ([Report]) -> Void) {
        self.onReports = onReports
    }

    static func register(onReports: @escaping @Sendable ([Report]) -> Void) -> CrashReporter {
        let reporter = CrashReporter(onReports: onReports)
        MXMetricManager.shared.add(reporter)
        return reporter
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var reports: [Report] = []
        for payload in payloads {
            let date = payload.timeStampEnd
            for crash in payload.crashDiagnostics ?? [] {
                if let parsed = DiagnosticParser.crash(from: crash.jsonRepresentation()) {
                    reports.append(Report(name: parsed.name, properties: parsed.properties, date: date))
                }
            }
            for hang in payload.hangDiagnostics ?? [] {
                if let parsed = DiagnosticParser.hang(from: hang.jsonRepresentation()) {
                    reports.append(Report(name: parsed.name, properties: parsed.properties, date: date))
                }
            }
        }
        if !reports.isEmpty { onReports(reports) }
    }
}
#endif
