# Atriya for iOS and macOS

App analytics and crash reports for SwiftUI and UIKit/AppKit apps, sent to your
Atriya backend. iOS 16+ and macOS 13+.

- **Usage:** active users, sessions and time in the app, screens, retention
- **Your events:** e.g. `timer_started`, optionally with a value (counts as revenue)
- **Versions and devices:** app version, OS version, device model
- **Crashes and hangs:** via Apple's MetricKit, with the stack of the affected thread
- **Privacy:** an anonymous install ID instead of the advertising ID, so no
  tracking prompt; `Atriya.optOut()` stops recording

Screens count like pageviews, so sessions, funnels, goals and retention in the
dashboard work for apps the same way as for websites.

## Setup

1. In the Atriya dashboard, open your project → Settings → Platforms and add an
   **iOS app** or **Mac app**. Copy its key.
2. Add the package to your app: in Xcode choose File → Add Package
   Dependencies…, enter `https://github.com/atriya-hq/atriya-swift` and add the
   `Atriya` library to your app target. In a `Package.swift`:

   ```swift
   .package(url: "https://github.com/atriya-hq/atriya-swift", from: "0.1.0")
   // in your target's dependencies:
   .product(name: "Atriya", package: "atriya-swift")
   ```

3. Start the SDK early:

```swift
import Atriya
import SwiftUI

@main
struct SimpleTimeApp: App {
    init() {
        Atriya.start(apiKey: "atr_pk_…", baseURL: URL(string: "https://api.atriya.io")!)
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Apps talking to a local backend over plain HTTP need
`NSAppTransportSecurity` → `NSAllowsLocalNetworking` in their Info.plist.

## Recording

```swift
// Screens – once per appearance
TimerView().atriyaScreen("Timer")       // SwiftUI
Atriya.screen("Timer")                  // anywhere else

// Your own events
Atriya.track("timer_started", properties: ["project": "Website", "billable": true])
Atriya.track("pro_upgrade", value: 29.99)

// Handled errors show up next to crashes
Atriya.track(error: error)

// Link the install to an account; call reset() on logout
Atriya.identify(userId: user.id, email: user.email, name: user.name)
Atriya.reset()
```

Recorded automatically: `app_install`, `app_update`, `app_open` (after at
least a minute in the background) and `app_background` with the seconds spent
in the foreground.

## How it works

Events are queued and sent in batches every 15 seconds, when 30 are waiting
and when the app goes to the background. Each event carries `offsetMs`, the
time between the event and the upload, so the server places it correctly even
if the device clock is wrong. Undelivered events are written to the caches
directory and sent on the next launch.

MetricKit delivers crash reports on the next launch after a crash and hang
reports at most once a day. Stack frames are sent as `Binary +offset`;
turning them into function names (symbolication) is not supported yet.

## Development

```sh
swift test
ATRIYA_KEY=atr_pk_… swift run AtriyaDemo   # a few events from the command line
```

`Examples/AtriyaDemoApp` is a small iOS app for the Simulator; see its
`project.yml` for build instructions (requires XcodeGen).

## License

MIT, see [LICENSE](LICENSE).
