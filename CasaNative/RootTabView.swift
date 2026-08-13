import SwiftUI

struct RootTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            Tab("Dashboard", systemImage: "gauge.with.dots.needle.67percent") {
                NavigationStack {
                    DashboardView(model: model)
                }
            }

            Tab("Apps", systemImage: "square.grid.2x2") {
                NavigationStack {
                    AppsView(client: model.client, serverURL: model.serverURL)
                }
            }

            Tab("Files", systemImage: "folder") {
                NavigationStack {
                    FilesView(client: model.client)
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView(model: model)
                }
            }
        }
    }
}
