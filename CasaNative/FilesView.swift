import SwiftUI
import UniformTypeIdentifiers
import QuickLook
@preconcurrency import QuickLookThumbnailing
import UIKit

struct FilesView: View {
    private static let maximumInMemoryTransferBytes: Int64 = 128 * 1_024 * 1_024

    let client: any CasaOSClient
    var path: String = CasaFile.rootPath

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("filesDisplayStyle") private var displayStyleValue = CasaFileDisplayStyle.list.rawValue
    @StateObject private var thumbnailStore = CasaFileThumbnailStore()
    @State private var files: [CasaFile] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var showLocationPrompt = false
    @State private var folderName = ""
    @State private var locationInput = ""
    @State private var navigationTarget: CasaFileLocation?
    @State private var pendingDelete: CasaFile?
    @State private var pendingRename: CasaFile?
    @State private var renameInput = ""
    @State private var pendingTransfer: CasaFileTransferRequest?
    @State private var activityMessage: String?
    @State private var queuedOperationMessage: String?
    @State private var uploadProgress: CasaFileUploadProgress?
    @State private var uploadSummary: CasaFileUploadSummary?
    @State private var uploadTask: Task<Void, Never>?
    @State private var previewURL: URL?
    @State private var ownedPreviewURL: URL?
    @State private var previewTask: Task<Void, Never>?
    @State private var exportDocument: CasaDownloadDocument?
    @State private var exportFilename = "download"
    @State private var showExporter = false

    var body: some View {
        dialogsContent
    }

    private var baseContent: some View {
        Group {
            if files.isEmpty, isLoading {
                ProgressView("Loading files…")
            } else if files.isEmpty, let errorMessage {
                ContentUnavailableView(
                    "Files Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if files.isEmpty {
                ContentUnavailableView(
                    "Folder Is Empty",
                    systemImage: "folder",
                    description: Text(displayPath)
                )
            } else if displayStyle == .list {
                fileList
            } else {
                fileGrid
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            locationBar
        }
        .refreshable { await loadFiles(clearThumbnails: true) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let parentPath {
                    Button("Up", systemImage: "arrow.up") {
                        navigate(to: parentPath)
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("View", systemImage: displayStyle.toolbarIconName) {
                    Picker("Layout", selection: $displayStyleValue) {
                        Label("List", systemImage: "list.bullet")
                            .tag(CasaFileDisplayStyle.list.rawValue)
                        Label("Grid", systemImage: "square.grid.2x2")
                            .tag(CasaFileDisplayStyle.grid.rawValue)
                    }
                }
                Menu("Location", systemImage: "location") {
                    Button("Go to path…", systemImage: "location.magnifyingglass") {
                        locationInput = path
                        showLocationPrompt = true
                    }
                    Divider()
                    Button("CasaOS Data", systemImage: "internaldrive") {
                        navigate(to: CasaFile.rootPath)
                    }
                    .disabled(path == CasaFile.rootPath)
                    Button("Server root", systemImage: "server.rack") {
                        navigate(to: CasaFile.serverRootPath)
                    }
                    .disabled(path == CasaFile.serverRootPath)
                }
                if isValidDirectory {
                    Menu("Add", systemImage: "plus") {
                        Button("New folder", systemImage: "folder.badge.plus") {
                            folderName = ""
                            showNewFolder = true
                        }
                        Button("Upload files", systemImage: "square.and.arrow.up") {
                            showImporter = true
                        }
                        .disabled(uploadTask != nil)
                    }
                }
            }
        }
    }

    private var lifecycleContent: some View {
        baseContent
        .navigationDestination(item: $navigationTarget) { location in
            FilesView(client: client, path: location.path)
        }
        .task { await loadFiles() }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, newValue in
            if newValue == nil {
                removePreparedPreview()
            }
        }
        .onDisappear {
            uploadTask?.cancel()
            uploadProgress = nil
            previewTask?.cancel()
            previewTask = nil
            removePreparedPreview()
            thumbnailStore.removeAll()
        }
        .onChange(of: displayStyleValue) { _, value in
            if value != CasaFileDisplayStyle.grid.rawValue {
                thumbnailStore.removeAll()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                thumbnailStore.removeAll()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )
        ) { _ in
            thumbnailStore.removeAll()
        }
    }

    private var presentationContent: some View {
        lifecycleContent
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentTypes: [.data],
            defaultFilename: exportFilename,
            onCompletion: { result in
                exportDocument = nil
                if case let .failure(error) = result {
                    errorMessage = error.localizedDescription
                }
            },
            onCancellation: {
                exportDocument = nil
            }
        )
        .sheet(item: $pendingTransfer) { request in
            NavigationStack {
                DestinationFolderPicker(
                    client: client,
                    path: CasaFile.serverRootPath,
                    source: request.source,
                    operation: request.operation
                ) { destination in
                    pendingTransfer = nil
                    Task {
                        await transfer(
                            request.source,
                            to: destination,
                            operation: request.operation
                        )
                    }
                }
            }
        }
        .sheet(item: $uploadSummary) { summary in
            NavigationStack {
                CasaFileUploadSummaryView(summary: summary) {
                    uploadSummary = nil
                }
            }
        }
    }

    private var dialogsContent: some View {
        presentationContent
        .alert("Go to server path", isPresented: $showLocationPrompt) {
            TextField("/absolute/path", text: $locationInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Go") { navigateToEnteredLocation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter an absolute folder path on the CasaOS server.")
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $folderName)
            Button("Create") { Task { await createFolder() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create inside \(displayPath).")
        }
        .alert(
            "Rename \(pendingRename?.name ?? "item")",
            isPresented: Binding(
                get: { pendingRename != nil },
                set: { if !$0 { pendingRename = nil } }
            )
        ) {
            TextField("Name", text: $renameInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") {
                guard let file = pendingRename else { return }
                pendingRename = nil
                Task { await rename(file, to: renameInput) }
            }
            Button("Cancel", role: .cancel) { pendingRename = nil }
        } message: {
            Text("Rename this item in its current folder.")
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "item")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                guard let file = pendingDelete else { return }
                pendingDelete = nil
                Task { await delete(file) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("CasaOS deletes this item recursively. This cannot be undone.")
        }
        .alert(
            "File operation failed",
            isPresented: Binding(
                get: { errorMessage != nil && !files.isEmpty },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var displayStyle: CasaFileDisplayStyle {
        CasaFileDisplayStyle(storedValue: displayStyleValue)
    }

    private var fileList: some View {
        List(files) { file in
            fileItem(file) {
                FileRow(file: file)
            }
            .swipeActions(edge: .trailing) {
                if canMutate(file) {
                    deleteButton(file)
                }
            }
        }
    }

    private var fileGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: 12)],
                spacing: 12
            ) {
                ForEach(files) { file in
                    fileItem(file) {
                        FileGridTile(
                            file: file,
                            client: client,
                            thumbnailStore: thumbnailStore,
                            loadsThumbnail: scenePhase == .active
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func fileItem<Label: View>(
        _ file: CasaFile,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Group {
            if file.isDirectory {
                NavigationLink {
                    FilesView(client: client, path: file.path)
                } label: {
                    label()
                }
            } else {
                Button {
                    startPreview(file)
                } label: {
                    label()
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu { fileActions(file) }
    }

    @ViewBuilder
    private func deleteButton(_ file: CasaFile) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            pendingDelete = file
        }
    }

    @ViewBuilder
    private func fileActions(_ file: CasaFile) -> some View {
        if !file.isDirectory {
            Button("Preview", systemImage: "eye") {
                startPreview(file)
            }
            Button("Download", systemImage: "square.and.arrow.down") {
                Task { await download(file) }
            }
        }
        if canMutate(file) {
            if !file.isDirectory {
                Divider()
            }
            Button("Rename", systemImage: "pencil") {
                renameInput = file.name
                pendingRename = file
            }
            Button("Copy", systemImage: "doc.on.doc") {
                pendingTransfer = CasaFileTransferRequest(source: file, operation: .copy)
            }
            Button("Move", systemImage: "folder") {
                pendingTransfer = CasaFileTransferRequest(source: file, operation: .move)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDelete = file
            }
        }
    }

    private var locationBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.orange)
                Text("Requests use your signed-in CasaOS session. CasaOS service and host permissions decide access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if let activityMessage {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(activityMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if let uploadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView(
                            value: Double(uploadProgress.completedCount),
                            total: Double(uploadProgress.totalCount)
                        )
                        .progressViewStyle(.linear)
                        Text(uploadProgress.countDescription)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let currentName = uploadProgress.currentName {
                        Text("Uploading \(currentName)")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if uploadProgress.failedCount > 0 {
                        Text("\(uploadProgress.failedCount) failed so far; details will appear when the batch finishes.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityElement(children: .combine)
            }

            if let queuedOperationMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock.badge.checkmark")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("File operation queued")
                            .font(.caption.weight(.semibold))
                        Text(queuedOperationMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Dismiss", systemImage: "xmark") {
                        self.queuedOperationMessage = nil
                    }
                    .labelStyle(.iconOnly)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .background(.bar)
    }

    private var displayPath: String {
        path == CasaFile.rootPath ? "CasaOS Data" : path
    }

    private var navigationTitle: String {
        if path == CasaFile.rootPath { return "Files" }
        if path == CasaFile.serverRootPath { return "Server" }
        return (path as NSString).lastPathComponent
    }

    private var isValidDirectory: Bool {
        CasaFilePathPolicy.normalizedAbsolutePath(path) != nil
    }

    private var parentPath: String? {
        CasaFilePathPolicy.parent(of: path)
    }

    private func canMutate(_ file: CasaFile) -> Bool {
        guard let normalized = CasaFilePathPolicy.normalizedAbsolutePath(file.path) else {
            return false
        }
        return normalized != CasaFile.serverRootPath
    }

    private func navigate(to path: String) {
        guard let path = CasaFilePathPolicy.normalizedAbsolutePath(path),
              path != self.path else { return }
        navigationTarget = CasaFileLocation(path: path)
    }

    private func navigateToEnteredLocation() {
        guard let path = CasaFilePathPolicy.normalizedAbsolutePath(
            locationInput.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            errorMessage = "Enter an absolute server path without . or .. components."
            return
        }
        navigate(to: path)
    }

    private func loadFiles(clearThumbnails: Bool = false) async {
        guard !isLoading else { return }
        if clearThumbnails {
            thumbnailStore.removeAll()
        }
        isLoading = true
        defer { isLoading = false }
        do {
            files = try await client.listFiles(at: path)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createFolder() async {
        let cleanName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeItemName(cleanName) else {
            errorMessage = "Folder names cannot be empty, use . or .., contain a slash, or contain control characters."
            return
        }
        let separator = path.isEmpty || path.hasSuffix("/") ? "" : "/"
        do {
            try await client.createFolder(at: path + separator + cleanName)
            await loadFiles(clearThumbnails: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFiles(_ result: Result<[URL], any Error>) {
        guard uploadTask == nil else { return }
        uploadTask = Task { @MainActor in
            defer {
                uploadProgress = nil
                uploadTask = nil
            }
            do {
                let urls = try result.get()
                guard !urls.isEmpty else { return }
                let summary = try await CasaFileUploadBatch.upload(
                    urls: urls,
                    to: path,
                    maximumBytes: Self.maximumInMemoryTransferBytes,
                    uploader: { [client] data, name, directory in
                        try await client.uploadFile(data: data, named: name, to: directory)
                    },
                    onProgress: { progress in
                        uploadProgress = progress
                    }
                )
                try Task.checkCancellation()
                await loadFiles(clearThumbnails: true)
                try Task.checkCancellation()
                uploadSummary = summary
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func download(_ file: CasaFile) async {
        guard activityMessage == nil else { return }
        activityMessage = "Preparing \(file.name) for download…"
        defer { activityMessage = nil }
        do {
            guard file.size <= Self.maximumInMemoryTransferBytes else {
                throw CasaOSError.contract(
                    "Files larger than 128 MB are not loaded into memory. Use the CasaOS web file manager for this transfer."
                )
            }
            exportDocument = CasaDownloadDocument(data: try await client.downloadFile(at: file.path))
            exportFilename = file.name
            showExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startPreview(_ file: CasaFile) {
        guard !file.isDirectory, activityMessage == nil else { return }
        previewTask?.cancel()
        previewTask = Task { await preview(file) }
    }

    private func preview(_ file: CasaFile) async {
        activityMessage = "Preparing \(file.name) for preview…"
        defer { activityMessage = nil }
        do {
            let preparedURL = try await client.prepareFileForPreview(
                at: file.path,
                named: file.name
            )
            guard !Task.isCancelled else {
                removePreparedPreview(at: preparedURL)
                return
            }
            removePreparedPreview()
            ownedPreviewURL = preparedURL
            previewURL = preparedURL
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func removePreparedPreview() {
        guard let url = ownedPreviewURL else { return }
        ownedPreviewURL = nil
        if previewURL == url {
            previewURL = nil
        }

        removePreparedPreview(at: url)
    }

    private func removePreparedPreview(at url: URL) {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path.hasPrefix(temporaryRoot.path + "/") else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    private func rename(_ file: CasaFile, to proposedName: String) async {
        guard canMutate(file), activityMessage == nil else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeItemName(name),
              let parent = CasaFilePathPolicy.parent(of: file.path) else {
            errorMessage = "Names cannot be empty, use . or .., contain a slash, or contain control characters."
            return
        }

        let destination = (parent as NSString).appendingPathComponent(name)
        guard let destination = CasaFilePathPolicy.normalizedAbsolutePath(destination),
              destination != CasaFile.serverRootPath else {
            errorMessage = "Choose a safe absolute server path. CasaOS service and host permissions still apply."
            return
        }
        guard destination != file.path else { return }

        activityMessage = "Renaming \(file.name)…"
        defer { activityMessage = nil }
        do {
            try await client.renameItem(
                at: file.path,
                to: destination,
                isDirectory: file.isDirectory
            )
            await loadFiles(clearThumbnails: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func transfer(
        _ file: CasaFile,
        to destination: String,
        operation: CasaFileOperation
    ) async {
        guard canMutate(file),
              CasaFilePathPolicy.normalizedAbsolutePath(destination) != nil,
              activityMessage == nil else { return }
        if file.isDirectory,
           (destination == file.path || destination.hasPrefix(file.path + "/")) {
            errorMessage = "A folder cannot be copied or moved into itself."
            return
        }

        activityMessage = "Requesting \(operation.displayName.lowercased()) of \(file.name)…"
        defer { activityMessage = nil }
        do {
            try await client.transferItems(
                at: [file.path],
                to: destination,
                operation: operation,
                collisionPolicy: .skip
            )
            thumbnailStore.removeAll()
            queuedOperationMessage = "CasaOS accepted the \(operation.displayName.lowercased()) request. Pull to refresh to see when it finishes. Existing same-name items are skipped."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ file: CasaFile) async {
        do {
            try await client.deleteFiles(at: [file.path])
            await loadFiles(clearThumbnails: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isSafeItemName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

struct CasaFileUploadFailure: Identifiable, Equatable, Sendable {
    let selectionIndex: Int
    let filename: String
    let message: String

    var id: Int { selectionIndex }
}

struct CasaFileUploadProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let currentName: String?
    let failedCount: Int

    var countDescription: String {
        "\(completedCount) of \(totalCount) processed"
    }
}

struct CasaFileUploadSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let totalCount: Int
    let succeededCount: Int
    let failures: [CasaFileUploadFailure]

    init(
        id: UUID = UUID(),
        totalCount: Int,
        succeededCount: Int,
        failures: [CasaFileUploadFailure]
    ) {
        self.id = id
        self.totalCount = totalCount
        self.succeededCount = succeededCount
        self.failures = failures
    }
}

enum CasaFileUploadBatch {
    static func upload(
        urls: [URL],
        to directory: String,
        maximumBytes: Int64,
        reader: @escaping @Sendable (URL, Int64) throws -> Data = readSecurityScopedFile,
        uploader: @escaping @Sendable (Data, String, String) async throws -> Void,
        onProgress: @escaping @MainActor @Sendable (CasaFileUploadProgress) -> Void
    ) async throws -> CasaFileUploadSummary {
        var failures: [CasaFileUploadFailure] = []
        var succeededCount = 0

        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            await onProgress(CasaFileUploadProgress(
                completedCount: index,
                totalCount: urls.count,
                currentName: url.lastPathComponent,
                failedCount: failures.count
            ))

            do {
                let readTask = Task.detached(priority: .userInitiated) {
                    try reader(url, maximumBytes)
                }
                let data = try await withTaskCancellationHandler {
                    try await readTask.value
                } onCancel: {
                    readTask.cancel()
                }
                try Task.checkCancellation()
                try await uploader(data, url.lastPathComponent, directory)
                succeededCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(CasaFileUploadFailure(
                    selectionIndex: index,
                    filename: url.lastPathComponent,
                    message: error.localizedDescription
                ))
            }

            await onProgress(CasaFileUploadProgress(
                completedCount: index + 1,
                totalCount: urls.count,
                currentName: nil,
                failedCount: failures.count
            ))
        }

        return CasaFileUploadSummary(
            totalCount: urls.count,
            succeededCount: succeededCount,
            failures: failures
        )
    }

    static func readSecurityScopedFile(from url: URL, maximumBytes: Int64) throws -> Data {
        try Task.checkCancellation()
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readResult: Result<Data, any Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            readResult = Result {
                try Task.checkCancellation()
                let values = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = values.fileSize,
                   Int64(fileSize) > maximumBytes {
                    throw CasaOSError.contract(
                        "Files larger than 128 MB are not loaded into memory. Use the CasaOS web file manager for this transfer."
                    )
                }
                return try CasaFileDataReader.readForUpload(
                    from: coordinatedURL,
                    maximumBytes: maximumBytes
                )
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let readResult else {
            throw CasaOSError.contract("The selected file could not be read safely.")
        }
        return try readResult.get()
    }
}

private struct CasaFileUploadSummaryView: View {
    let summary: CasaFileUploadSummary
    let onDone: () -> Void

    var body: some View {
        List {
            Section {
                Label(
                    "\(summary.succeededCount) uploaded",
                    systemImage: summary.succeededCount > 0 ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(summary.succeededCount > 0 ? .green : .secondary)

                if !summary.failures.isEmpty {
                    Label(
                        "\(summary.failures.count) failed",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            } header: {
                Text("\(summary.totalCount) selected")
            }

            if !summary.failures.isEmpty {
                Section("Couldn’t upload") {
                    ForEach(summary.failures) { failure in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(failure.filename)
                                .font(.body.weight(.semibold))
                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle(summary.failures.isEmpty ? "Upload Complete" : "Upload Results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
    }
}

private struct CasaFileLocation: Hashable, Identifiable {
    let path: String
    var id: String { path }
}

private struct CasaFileTransferRequest: Identifiable {
    let id = UUID()
    let source: CasaFile
    let operation: CasaFileOperation
}

private struct DestinationFolderPicker: View {
    @Environment(\.dismiss) private var dismiss

    let client: any CasaOSClient
    let path: String
    let source: CasaFile
    let operation: CasaFileOperation
    let onSelect: (String) -> Void

    @State private var folders: [CasaFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if folders.isEmpty, isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Loading folders…")
                        Spacer()
                    }
                } else if folders.isEmpty {
                    Text(errorMessage == nil ? "No subfolders" : "Folders unavailable")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        NavigationLink {
                            DestinationFolderPicker(
                                client: client,
                                path: folder.path,
                                source: source,
                                operation: operation,
                                onSelect: onSelect
                            )
                        } label: {
                            Label(folder.name, systemImage: "folder.fill")
                                .foregroundStyle(.primary, .blue)
                        }
                    }
                }
            } header: {
                Text(path)
                    .textCase(nil)
                    .font(.caption.monospaced())
            }

            Section {
                Text("If an item named \(source.name) already exists here, CasaOS skips it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Requests use your signed-in session. CasaOS service and host permissions decide whether this folder can be changed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("\(operation.displayName) to…")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(operation.displayName) { onSelect(path) }
                    .disabled(!canChooseCurrentFolder)
            }
        }
        .refreshable { await loadFolders() }
        .task { await loadFolders() }
        .alert(
            "Folders unavailable",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var canChooseCurrentFolder: Bool {
        guard CasaFilePathPolicy.normalizedAbsolutePath(path) != nil else { return false }
        if path == CasaFilePathPolicy.parent(of: source.path) { return false }
        guard source.isDirectory else { return true }
        return path != source.path && !path.hasPrefix(source.path + "/")
    }

    private func loadFolders() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await client.listFiles(at: path)
                .filter { folder in
                    guard folder.isDirectory else { return false }
                    guard source.isDirectory else { return true }
                    return folder.path != source.path
                        && !folder.path.hasPrefix(source.path + "/")
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension CasaFileOperation {
    var displayName: String {
        switch self {
        case .copy: "Copy"
        case .move: "Move"
        }
    }
}

enum CasaFileDisplayStyle: String, CaseIterable, Sendable {
    case list
    case grid

    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .list
    }

    var toolbarIconName: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        }
    }
}

enum CasaFilePresentation {
    static let maximumAutomaticThumbnailBytes: Int64 = 16 * 1_024 * 1_024

    private static let thumbnailExtensions: Set<String> = [
        "bmp", "csv", "doc", "docx", "gif", "heic", "heif", "jpeg", "jpg",
        "json", "key", "m4v", "md", "mov", "mp4", "numbers", "pages", "pdf",
        "png", "ppt", "pptx", "rtf", "tif", "tiff", "txt", "webp", "xls",
        "xlsx", "xml", "yaml", "yml",
    ]

    static func iconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "heic"].contains(ext) { return "photo" }
        if ["mp4", "mov", "mkv"].contains(ext) { return "film" }
        if ["mp3", "m4a", "flac"].contains(ext) { return "music.note" }
        if ext == "pdf" { return "doc.richtext" }
        return "doc"
    }

    static func isThumbnailEligible(_ file: CasaFile) -> Bool {
        guard !file.isDirectory,
              file.size > 0,
              file.size <= maximumAutomaticThumbnailBytes else {
            return false
        }
        return thumbnailExtensions.contains(
            (file.name as NSString).pathExtension.lowercased()
        )
    }
}

private struct FileRow: View {
    let file: CasaFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.isDirectory ? "folder.fill" : iconName)
                .font(.title2)
                .foregroundStyle(file.isDirectory ? .blue : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if !file.isDirectory {
                        Text(file.size.formatted(.byteCount(style: .file)))
                    }
                    if let modified = file.modified {
                        Text(modified, format: .dateTime.year().month().day())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        CasaFilePresentation.iconName(for: file.name)
    }
}

private actor CasaFileThumbnailGate {
    private var availablePermits = 2
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private final class CasaFileThumbnailRequestBox: @unchecked Sendable {
    let request: QLThumbnailGenerator.Request

    init(request: QLThumbnailGenerator.Request) {
        self.request = request
    }

    func cancel() {
        QLThumbnailGenerator.shared.cancel(request)
    }
}

@MainActor
private final class CasaFileThumbnailStore: ObservableObject {
    private let cache = NSCache<NSString, UIImage>()
    private let gate = CasaFileThumbnailGate()

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func thumbnail(
        for file: CasaFile,
        client: any CasaOSClient,
        size: CGSize,
        scale: CGFloat
    ) async -> UIImage? {
        guard CasaFilePresentation.isThumbnailEligible(file) else { return nil }
        let key = cacheKey(for: file, client: client, scale: scale)
        if let image = cache.object(forKey: key) {
            return image
        }

        await gate.acquire()
        guard !Task.isCancelled else {
            await gate.release()
            return nil
        }

        var preparedURL: URL?
        do {
            let url = try await client.prepareFileForThumbnail(
                at: file.path,
                named: file.name
            )
            preparedURL = url
            try Task.checkCancellation()
            let image = try await generateThumbnail(from: url, size: size, scale: scale)
            try Task.checkCancellation()
            removePreparedThumbnail(at: url)
            preparedURL = nil
            await gate.release()
            cache.setObject(image, forKey: key, cost: memoryCost(of: image))
            return image
        } catch {
            if let preparedURL {
                removePreparedThumbnail(at: preparedURL)
            }
            await gate.release()
            return nil
        }
    }

    private func generateThumbnail(
        from url: URL,
        size: CGSize,
        scale: CGFloat
    ) async throws -> UIImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: [.lowQualityThumbnail, .thumbnail]
        )
        let requestBox = CasaFileThumbnailRequestBox(request: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                    representation,
                    error in
                    if let representation {
                        continuation.resume(returning: representation.uiImage)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            requestBox.cancel()
        }
    }

    private func cacheKey(
        for file: CasaFile,
        client: any CasaOSClient,
        scale: CGFloat
    ) -> NSString {
        let clientID = ObjectIdentifier(client as AnyObject).hashValue
        let modified = file.modified?.timeIntervalSinceReferenceDate ?? -1
        return "\(clientID)|\(file.path)|\(file.size)|\(modified)|\(scale)" as NSString
    }

    private func memoryCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.width * cgImage.height * 4
    }

    private func removePreparedThumbnail(at url: URL) {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.deletingLastPathComponent() == temporaryRoot,
              parent.lastPathComponent.hasPrefix("CasaNativeThumbnail-") else {
            return
        }
        try? FileManager.default.removeItem(at: parent)
    }
}

private struct FileGridTile: View {
    let file: CasaFile
    let client: any CasaOSClient
    @ObservedObject var thumbnailStore: CasaFileThumbnailStore
    let loadsThumbnail: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?
    @State private var isLoadingThumbnail = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.09))
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: file.isDirectory ? "folder.fill" : iconName)
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(file.isDirectory ? .blue : .secondary)
                }
                if isLoadingThumbnail {
                    ProgressView()
                        .controlSize(.small)
                        .padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(file.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text(metadata)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .top)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .task(id: thumbnailTaskID) {
            thumbnail = nil
            isLoadingThumbnail = false
            guard loadsThumbnail,
                  CasaFilePresentation.isThumbnailEligible(file) else {
                return
            }
            isLoadingThumbnail = true
            let image = await thumbnailStore.thumbnail(
                for: file,
                client: client,
                size: CGSize(width: 190, height: 88),
                scale: displayScale
            )
            guard !Task.isCancelled else { return }
            thumbnail = image
            isLoadingThumbnail = false
        }
    }

    private var iconName: String {
        CasaFilePresentation.iconName(for: file.name)
    }

    private var metadata: String {
        var parts = [file.isDirectory ? "Folder" : file.size.formatted(.byteCount(style: .file))]
        if let modified = file.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private var thumbnailTaskID: String {
        let modified = file.modified?.timeIntervalSinceReferenceDate ?? -1
        return "\(file.path)|\(file.size)|\(modified)|\(displayScale)|\(loadsThumbnail)"
    }
}

private struct CasaDownloadDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
