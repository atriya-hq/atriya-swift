# Atriya for iOS and macOS

App analytics and crash reports for SwiftUI and UIKit/AppKit apps, sent to your
Atriya backend. iOS 16+ and macOS 13+.

- **Usage:** active users, sessions and time in the app, screens, retention
- **Your events:** e.g. `timer_started`, optionally with a value (counts as revenue)
- **Versions and devices:** app version, OS version, device model
- **Crashes and hangs:** via Apple's MetricKit, with the stack of the affected thread –
  with functions, files and lines once you upload the dSYMs
- **Privacy:** an anonymous install ID instead of the advertising ID, so no
  tracking prompt; `Atriya.optOut()` stops recording; an
  [anonymous mode](#anonymous-mode) keeps nothing on the device at all

Screens count like pageviews, so sessions, funnels, goals and retention in the
dashboard work for apps the same way as for websites.

## Setup

1. In the Atriya dashboard, open your project → Settings → Platforms and add an
   **iOS app** or **Mac app**. Copy its key.
2. Add the package to your app: in Xcode choose File → Add Package
   Dependencies…, enter `https://github.com/atriya-hq/atriya-swift` and add the
   `Atriya` library to your app target. In a `Package.swift`:

   ```swift
   .package(url: "https://github.com/atriya-hq/atriya-swift", from: "0.1.4")
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
        Atriya.start(apiKey: "atr_pk_…", baseURL: URL(string: "https://intern.atriya.io")!)
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

`baseURL` is the address of your Atriya server – the same one the dashboard
runs on. Apps talking to a local backend over plain HTTP need
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

Recorded automatically: `app_install`, `app_update` (both not in anonymous
mode), `app_open` (after at least a minute in the background) and
`app_background` with the seconds spent in the foreground.

Visitors count every event, so an app shows up even before it marks a single
screen; screens add the screen views and which screens are used. After
`identify`, every event moves the user's “last seen” forward.

## Anonymous mode

```swift
var options = Atriya.Options()
options.anonymous = true
Atriya.start(apiKey: "atr_pk_…", baseURL: URL(string: "https://intern.atriya.io")!, options: options)
```

For apps that measure without asking. In the EU, storing an identifier on the
device or reading it back needs consent (Art. 5(3) ePrivacy Directive, § 25
TDDDG in Germany) – an install ID included. In anonymous mode the SDK keeps
nothing on the device:

- no install ID and no user ID; `identify` is ignored
- no `app_install` or `app_update`, which would need the last version on disk
- events that couldn't be sent stay in memory instead of the caches directory
- an install ID, user ID or waiting events from an earlier launch without
  anonymous mode are deleted on start

The batches say they are anonymous. The backend then tells devices apart for
one UTC day only, with a hash of a daily random salt, the IP address, the
User-Agent and the device model – the same way it counts visitors of cookieless
websites. It keeps the country but not region and city, and neither the
User-Agent nor a user ID.

What you get: active devices, opens and time in the app per day, screens,
events, versions, devices, countries, crashes and hangs. What you don't:
installs (take them from App Store Connect), retention and unique users over
more than a day. Crash-free figures count device-days.

The opt-out still applies and is the one thing the SDK stores – only once the
user turns recording off.

## Crash symbolication

Crash and hang stacks arrive as offsets into your binaries. Upload the debug
symbols (dSYMs) of each release build, and the dashboard shows the functions,
files and lines – including inlined calls – instead.

1. In the Atriya dashboard, open your project → Settings → **Debug symbols**
   and create an upload key (`atr_sk_…`). Keep it secret: unlike the app's
   key, it doesn't belong into the app.
2. After a release build, upload its dSYMs:

   ```sh
   ATRIYA_UPLOAD_KEY=atr_sk_… \
     .build/checkouts/atriya-swift/Scripts/upload-symbols.sh path/to/MyApp.app.dSYM
   ```

   Xcode keeps the package in DerivedData:
   `…/SourcePackages/checkouts/atriya-swift/Scripts/upload-symbols.sh`. The
   script takes `.dSYM` bundles or folders containing them, such as an
   `.xcarchive`, and sends the demangled Swift names along – that part needs a
   Mac with Xcode. `ATRIYA_URL` points it to your server
   (`https://intern.atriya.io` by default).

To upload with every build, add a Run Script phase after linking with
`"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/atriya-swift/Scripts/upload-symbols.sh"`,
`ATRIYA_UPLOAD_KEY` as a build setting and these input files, so Xcode runs it
once the dSYM exists:

```
${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${TARGET_NAME}
${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist
```

Debug builds have no dSYM and are skipped; a failed upload is a warning, not a
failed build. Only release builds need `DEBUG_INFORMATION_FORMAT =
dwarf-with-dsym` – Xcode's default.

## How it works

Events are queued and sent in batches every 15 seconds, when 30 are waiting
and when the app goes to the background. Each event carries `offsetMs`, the
time between the event and the upload, so the server places it correctly even
if the device clock is wrong. Undelivered events are written to the caches
directory and sent on the next launch.

MetricKit delivers crash reports on the next launch after a crash and hang
reports at most once a day. Stack frames are sent as `Binary +offset`, with
the UUID of each binary, so the backend can match them to the uploaded dSYMs.

## Privacy

The package ships a privacy manifest (`PrivacyInfo.xcprivacy`), so Xcode's
privacy report for your app lists what Atriya collects:

| Data | Purpose |
|---|---|
| Product interaction: screens, events, app opens | Analytics |
| Device ID: the anonymous install ID | Analytics |
| Coarse location: country, region and city, derived by the backend from the IP address | Analytics |
| Crash data and performance data (hangs) | App functionality |
| Other diagnostic data: app version, OS version, device model, handled errors | Analytics, app functionality |

None of it is used for tracking or linked to the user's identity – unless you
call `identify(userId:…)`. Then declare the data as linked to the user in App
Store Connect, together with the user ID and any email address or name you
pass.

In anonymous mode there is no device ID, and the location narrows to the
country. The manifest can't know the mode and still lists the device ID;
declare in App Store Connect what your app actually sends.

The only API that needs a declared reason is `UserDefaults` (`CA92.1`): it
keeps the install ID, the user ID and the opt-out – in anonymous mode only the
opt-out.

`Atriya.optOut()` stops recording and is remembered across launches, also when
called before `start`. Offer it as a switch in your app's settings. Events
recorded before it are dropped, not sent. If your app syncs its settings
between devices, sync `Atriya.optOutKey` (a key in the standard user defaults)
with them, and the opt-out applies on every device.

## Development

```sh
swift test
ATRIYA_KEY=atr_pk_… swift run AtriyaDemo   # a few events from the command line
```

`Examples/AtriyaDemoApp` is a small iOS app for the Simulator; see its
`project.yml` for build instructions (requires XcodeGen).

## License

MIT, see [LICENSE](LICENSE).
