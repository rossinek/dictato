import SwiftUI

enum MainWindowTab: Int, CaseIterable {
    case history = 0
    case settings = 1
}

struct MainWindowView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var selectedTab: MainWindowTab = AppState.shared.mainWindowTab

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("History", systemImage: "clock", value: .history) {
                HistoryView(appState: appState)
            }

            Tab("Settings", systemImage: "gear", value: .settings) {
                SettingsView()
            }
        }
        .onReceive(appState.$mainWindowTab) { tab in
            selectedTab = tab
        }
    }
}
