import Foundation
import SafariServices
import SwiftUI

enum AppsLoadErrorPolicy {
    static func userFacingMessage(
        for error: any Error,
        taskIsCancelled: Bool = Task.isCancelled
    ) -> String? {
        guard !taskIsCancelled else { return nil }
        guard !(error is CancellationError) else { return nil }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return nil
        }
        return error.localizedDescription
    }
}

struct AppsView: View {
    let client: any CasaOSClient
    let serverURL: URL

    @State private var apps: [CasaApp] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var needsReloadAfterCancellation = false
    @State private var changingAppID: String?
    @State private var browserDestination: BrowserDestination?

    var body: some View {
        Group {
            if apps.isEmpty, isLoading {
                ProgressView("Loading apps…")
            } else if apps.isEmpty, let errorMessage {
                ContentUnavailableView(
                    "Apps Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if apps.isEmpty {
                ContentUnavailableView(
                    "No Compose Apps",
                    systemImage: "square.grid.2x2",
                    description: Text("Installed CasaOS compose apps appear here.")
                )
            } else {
                List(apps) { app in
                    AppRow(
                        app: app,
                        serverURL: serverURL,
                        isChanging: changingAppID == app.id,
                        open: { url in browserDestination = BrowserDestination(url: url) },
                        action: { action in Task { await apply(action, to: app) } }
                    )
                }
            }
        }
        .navigationTitle("Apps")
        .onAppear {
            Task { await retryCancelledLoadIfNeeded() }
        }
        .refreshable { await loadApps() }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await loadApps() }
            }
            .disabled(isLoading)
        }
        .task { await loadApps() }
        .alert(
            "App operation failed",
            isPresented: Binding(
                get: { errorMessage != nil && !apps.isEmpty },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .fullScreenCover(item: $browserDestination) { destination in
            InAppBrowser(url: destination.url)
                .ignoresSafeArea()
        }
    }

    private func loadApps() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            apps = try await client.fetchApps()
            errorMessage = nil
            needsReloadAfterCancellation = false
        } catch {
            if let message = AppsLoadErrorPolicy.userFacingMessage(for: error) {
                errorMessage = message
            } else {
                needsReloadAfterCancellation = true
            }
        }
    }

    private func retryCancelledLoadIfNeeded() async {
        while isLoading {
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
        }
        guard needsReloadAfterCancellation, apps.isEmpty else { return }
        needsReloadAfterCancellation = false
        await loadApps()
    }

    private func apply(_ action: AppAction, to app: CasaApp) async {
        changingAppID = app.id
        defer { changingAppID = nil }
        do {
            try await client.setAppStatus(action, appID: app.id)
            try? await Task.sleep(for: .seconds(1))
            apps = try await client.fetchApps()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AppRow: View {
    let app: CasaApp
    let serverURL: URL
    let isChanging: Bool
    let open: (URL) -> Void
    let action: (AppAction) -> Void

    private var launchURL: URL? {
        guard app.isRunning else { return nil }
        return app.launchURL(relativeTo: serverURL)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let launchURL {
                    open(launchURL)
                }
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: app.iconURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "shippingbox.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .frame(width: 42, height: 42)
                    .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.headline)
                        Label(app.isRunning ? "Running" : app.status.capitalized, systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(app.isRunning ? .green : .secondary)
                    }
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(launchURL == nil)

            if isChanging {
                ProgressView()
            } else {
                Menu {
                    if let launchURL {
                        Button("Open", systemImage: "arrow.up.forward.app") { open(launchURL) }
                    }
                    Button(app.isRunning ? "Stop" : "Start", systemImage: app.isRunning ? "stop.fill" : "play.fill") {
                        action(app.isRunning ? .stop : .start)
                    }
                    Button("Restart", systemImage: "arrow.clockwise") { action(.restart) }
                        .disabled(!app.isRunning)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BrowserDestination: Identifiable {
    let url: URL

    var id: URL { url }
}

private struct InAppBrowser: UIViewControllerRepresentable {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, @MainActor SFSafariViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        @MainActor
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            dismiss()
        }
    }
}
