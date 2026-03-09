import SwiftUI

@main
struct DictatoApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView(appState: appState)
            }
            .task {
                await appState.requestPermissions()
                await appState.initializeASR()
            }
        }
    }
}
