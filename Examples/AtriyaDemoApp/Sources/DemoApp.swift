import Atriya
import SwiftUI

@main
struct DemoApp: App {
    init() {
        let info = Bundle.main.infoDictionary
        if let key = info?["AtriyaKey"] as? String, !key.isEmpty,
           let url = (info?["AtriyaURL"] as? String).flatMap(URL.init(string:)) {
            Atriya.start(apiKey: key, baseURL: url)
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                TimerScreen()
                    .atriyaScreen("Timer")
                    .tabItem { Label("Timer", systemImage: "timer") }
                ProjectsScreen()
                    .atriyaScreen("Projekte")
                    .tabItem { Label("Projekte", systemImage: "folder") }
            }
        }
    }
}

struct TimerScreen: View {
    @State private var running = false

    var body: some View {
        VStack(spacing: 24) {
            Text(running ? "Läuft …" : "Bereit").font(.largeTitle.bold())
            Button(running ? "Timer stoppen" : "Timer starten") {
                running.toggle()
                Atriya.track(running ? "timer_started" : "timer_stopped", properties: ["project": "Website"])
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct ProjectsScreen: View {
    struct SyncError: Error, CustomStringConvertible {
        var description: String { "Projekte konnten nicht geladen werden" }
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Projekte").font(.largeTitle.bold())
            Button("Fehler simulieren") {
                Atriya.track(error: SyncError())
            }
            .buttonStyle(.bordered)
        }
    }
}
