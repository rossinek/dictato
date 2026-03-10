import SwiftUI

enum MainWindowTab: String, CaseIterable {
    case history = "History"
    case settings = "Settings"
}

struct MainWindowView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var selectedTab: MainWindowTab = AppState.shared.mainWindowTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(MainWindowTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)

            switch selectedTab {
            case .history:
                HistoryView(appState: appState)
            case .settings:
                SettingsView()
            }
        }
        .onReceive(appState.$mainWindowTab) { tab in
            selectedTab = tab
        }
    }
}
