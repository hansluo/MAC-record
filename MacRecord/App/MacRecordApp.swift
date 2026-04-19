import SwiftUI
import SwiftData

@main
struct MacRecordApp: App {
    @StateObject private var appState = AppState()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Recording.self,
            AISummary.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        // 主窗口
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1200, height: 800)

        // 设置
        Settings {
            SettingsView()
                .environmentObject(appState)
                .modelContainer(sharedModelContainer)
        }

        // 菜单栏常驻
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: menuBarIconName)
        }
    }

    private var menuBarIconName: String {
        switch appState.voiceInputService.state {
        case .idle: return "mic.badge.plus"
        case .recording: return "mic.fill"
        case .correcting: return "sparkles"
        case .injecting: return "text.cursor"
        }
    }
}
