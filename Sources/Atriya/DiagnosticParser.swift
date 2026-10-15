import Foundation

/// Turns MetricKit diagnostics (their `jsonRepresentation()`) into error
/// events. Kept free of MetricKit so it can be tested with fixture JSON.
enum DiagnosticParser {
    struct Report: Equatable {
        var name: String
        var properties: [String: AtriyaValue]
    }

    /// Frames of the crashing thread sent along; enough to spot the culprit
    /// while staying far below the backend's 8 KB property limit.
    static let maxFrames = 25

    static func crash(from json: Data) -> Report? {
        guard let root = object(json), let meta = root["diagnosticMetaData"] as? [String: Any] else {
            return nil
        }
        let exception = (meta["exceptionType"] as? Int).map(exceptionName)
        let signal = (meta["signal"] as? Int).map(signalName)
        let reason = meta["terminationReason"] as? String
        let title = [exception, signal.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")

        var properties = common(meta: meta, root: root)
        properties["kind"] = "crash"
        if let exception { properties["exceptionType"] = .string(exception) }
        if let code = meta["exceptionCode"] as? Int { properties["exceptionCode"] = .int(code) }
        if let signal { properties["signal"] = .string(signal) }
        if let reason { properties["terminationReason"] = .string(String(reason.prefix(500))) }

        let name = title.isEmpty ? (reason.map { String($0.prefix(200)) } ?? "Unknown") : title
        return Report(name: "Crash: \(name)", properties: properties)
    }

    static func hang(from json: Data) -> Report? {
        guard let root = object(json), let meta = root["diagnosticMetaData"] as? [String: Any] else {
            return nil
        }
        let duration = meta["hangDuration"] as? String ?? "?"
        var properties = common(meta: meta, root: root)
        properties["kind"] = "hang"
        properties["duration"] = .string(duration)
        return Report(name: "Hang: \(duration)", properties: properties)
    }

    // MARK: - Helpers

    private static func object(_ json: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    private static func common(meta: [String: Any], root: [String: Any]) -> [String: AtriyaValue] {
        var properties: [String: AtriyaValue] = [:]
        for key in ["appVersion", "appBuildVersion", "osVersion", "deviceType", "platformArchitecture"] {
            if let value = meta[key] as? String { properties[key] = .string(value) }
        }
        let frames = crashingThreadFrames(root)
        if !frames.isEmpty {
            properties["frames"] = .string(frames.joined(separator: "\n"))
        }
        return properties
    }

    /// Walks the call stack of the attributed (crashing or hanging) thread
    /// from the innermost frame outwards: "SimpleTime +0x1a2b3c".
    static func crashingThreadFrames(_ root: [String: Any]) -> [String] {
        guard let tree = root["callStackTree"] as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        var frames: [String] = []
        while let current = frame, frames.count < maxFrames {
            let binary = current["binaryName"] as? String ?? "???"
            let offset = current["offsetIntoBinaryTextSegment"] as? Int ?? 0
            frames.append("\(binary) +0x\(String(offset, radix: 16))")
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }
        return frames
    }

    private static func exceptionName(_ type: Int) -> String {
        switch type {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        default: "EXC_\(type)"
        }
    }

    private static func signalName(_ signal: Int) -> String {
        switch signal {
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 8: "SIGFPE"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        case 13: "SIGPIPE"
        default: "SIG\(signal)"
        }
    }
}
