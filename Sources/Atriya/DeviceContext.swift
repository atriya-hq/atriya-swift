import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Describes the device once per batch. Native apps send a CFNetwork
/// User-Agent that says little, so the backend uses this instead.
struct DeviceContext: Encodable, Sendable, Equatable {
    var os: String
    var osVersion: String
    /// mobile, tablet or desktop – the same buckets the dashboard uses for the web.
    var deviceType: String
    /// Hardware identifier such as "iPhone15,3" or "Mac14,2".
    var deviceModel: String
    /// "1.4 (12)" from CFBundleShortVersionString and CFBundleVersion.
    var appVersion: String?
    var sdk: String

    @MainActor
    static func current(bundle: Bundle = .main) -> DeviceContext {
        // Mac Catalyst counts as iOS, but there UIDevice says "iPadOS" and uname
        // only knows "arm64" – the Mac branch describes it as the Mac it is.
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let device = UIDevice.current
        let deviceType: String
        switch device.userInterfaceIdiom {
        case .pad: deviceType = "tablet"
        case .mac: deviceType = "desktop"
        default: deviceType = "mobile"
        }
        return DeviceContext(
            os: device.systemName,
            osVersion: device.systemVersion,
            deviceType: deviceType,
            deviceModel: hardwareModel(),
            appVersion: appVersion(bundle),
            sdk: "atriya-swift/\(Atriya.sdkVersion)"
        )
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceContext(
            os: "macOS",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            deviceType: "desktop",
            deviceModel: hardwareModel(),
            appVersion: appVersion(bundle),
            sdk: "atriya-swift/\(Atriya.sdkVersion)"
        )
        #endif
    }

    static func appVersion(_ bundle: Bundle) -> String? {
        let info = bundle.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        case let (nil, build?): return build
        default: return nil
        }
    }

    private static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return model
        }
        #endif
        #if os(macOS) || targetEnvironment(macCatalyst)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }
}
