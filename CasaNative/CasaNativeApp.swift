import SwiftUI

@main
struct CasaNativeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(model.appearanceMode.colorScheme)
        }
    }
}

private struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.connectionState {
        case .checking:
            ProgressView("Checking CasaOS…")
        case .needsServer:
            NavigationStack {
                ConnectionView(model: model)
            }
        case .needsLogin:
            NavigationStack {
                LoginView(model: model)
            }
        case .connected:
            RootTabView(model: model)
        }
    }
}
