import Atriya
import Foundation

// Sends a short, realistic app session to a running Atriya backend:
//
//   ATRIYA_KEY=atr_pk_… ATRIYA_URL=http://localhost:3000 swift run AtriyaDemo
//
// ATRIYA_ANONYMOUS=1 runs it in anonymous mode (`Options.anonymous`).
//
// Lifecycle events need a real app, so this demo covers screens, custom
// events, identify and a handled error.

enum DemoError: Error, CustomStringConvertible {
    case syncFailed(code: Int)

    var description: String {
        switch self {
        case .syncFailed(let code): "Sync failed with status \(code)"
        }
    }
}

let environment = ProcessInfo.processInfo.environment
guard let key = environment["ATRIYA_KEY"] else {
    print("Set ATRIYA_KEY to the key of an iOS or macOS platform.")
    exit(1)
}
let baseURL = URL(string: environment["ATRIYA_URL"] ?? "http://localhost:3000")!

await MainActor.run {
    var options = Atriya.Options()
    options.reportCrashes = false
    options.anonymous = environment["ATRIYA_ANONYMOUS"] == "1"
    Atriya.start(apiKey: key, baseURL: baseURL, options: options)
}

func pause(_ milliseconds: Int) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

Atriya.screen("Timer")
await pause(400)
Atriya.track("timer_started", properties: ["project": "Website", "billable": true])
await pause(600)
Atriya.screen("Projekte")
await pause(300)
Atriya.identify(userId: "demo-swift-user", email: "swift-demo@example.com", name: "Swift Demo")
await pause(300)
Atriya.track(error: DemoError.syncFailed(code: 503))
await pause(300)
Atriya.screen("Statistik")
Atriya.track("export_csv", value: 4.99)

await Atriya.flush()
print("Sent – check the platform in the Atriya dashboard.")
