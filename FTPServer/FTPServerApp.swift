import SwiftUI

@main
struct FTPServerApp: App {
    @State private var controller: ServerController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let controller = ServerController(settings: ServerSettings())
        if controller.settings.startOnLaunch { controller.start() }
        _controller = State(initialValue: controller)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
        }
        .onChange(of: scenePhase) { _, phase in
            controller.scenePhaseChanged(to: phase)
        }
    }
}

struct ContentView: View {
    @AppStorage("selectedTab") private var selectedTab = "server"

    var body: some View {
        TabView(selection: $selectedTab) {
            ServerView()
                .tabItem { Label("Server", systemImage: "antenna.radiowaves.left.and.right") }
                .tag("server")
            FilesView()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag("files")
            ActivityView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag("activity")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
    }
}
