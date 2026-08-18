import Foundation

struct CasaFileTransferLimits: Equatable, Sendable {
    static let production = CasaFileTransferLimits(
        inMemoryBytes: 128 * 1_024 * 1_024,
        previewBytes: 1 * 1_024 * 1_024 * 1_024,
        uploadBytes: 128 * 1_024 * 1_024,
        thumbnailBytes: 16 * 1_024 * 1_024
    )

    let inMemoryBytes: Int64
    let previewBytes: Int64
    let uploadBytes: Int64
    let thumbnailBytes: Int64

    init(
        inMemoryBytes: Int64,
        previewBytes: Int64,
        uploadBytes: Int64,
        thumbnailBytes: Int64 = 16 * 1_024 * 1_024
    ) {
        precondition(
            inMemoryBytes > 0 && previewBytes > 0 && uploadBytes > 0 && thumbnailBytes > 0
        )
        self.inMemoryBytes = inMemoryBytes
        self.previewBytes = previewBytes
        self.uploadBytes = uploadBytes
        self.thumbnailBytes = thumbnailBytes
    }
}

enum CasaFileDataReader {
    static func readForUpload(from url: URL, maximumBytes: Int64) throws -> Data {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var result = Data()
        let chunkSize = 64 * 1_024
        while true {
            try Task.checkCancellation()
            let remaining = maximumBytes - Int64(result.count)
            guard remaining >= 0 else {
                throw transferLimitError(kind: "in-memory transfer", bytes: maximumBytes)
            }
            let requested = Int(min(Int64(chunkSize), remaining + 1))
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                return result
            }
            guard Int64(chunk.count) <= remaining else {
                throw transferLimitError(kind: "in-memory transfer", bytes: maximumBytes)
            }
            result.append(chunk)
        }
    }
}

private func transferLimitError(kind: String, bytes: Int64) -> CasaOSError {
    CasaOSError.contract(
        "This file exceeds Casa Native's \(formattedTransferLimit(bytes)) \(kind) limit."
    )
}

private func formattedTransferLimit(_ bytes: Int64) -> String {
    let gibibyte: Int64 = 1_024 * 1_024 * 1_024
    let mebibyte: Int64 = 1_024 * 1_024
    if bytes.isMultiple(of: gibibyte) {
        return "\(bytes / gibibyte) GiB"
    }
    if bytes.isMultiple(of: mebibyte) {
        return "\(bytes / mebibyte) MiB"
    }
    return "\(bytes) bytes"
}

private enum BoundedTransferDestination: Sendable {
    case memory
    case file(URL)
}

private struct BoundedTransferResponse: Sendable {
    let statusCode: Int
    let data: Data
    let fileURL: URL?
}

private final class BoundedURLSessionTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int64
    private let limitKind: String
    private let destination: BoundedTransferDestination
    private let lock = NSLock()

    private var continuation: CheckedContinuation<BoundedTransferResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var receivedBytes: Int64 = 0
    private var memoryData = Data()
    private var errorBody = Data()
    private var fileHandle: FileHandle?
    private var terminalError: (any Error)?
    private var cancelledAfterErrorBodyLimit = false
    private var completed = false

    init(
        configuration: URLSessionConfiguration,
        maximumBytes: Int64,
        limitKind: String,
        destination: BoundedTransferDestination
    ) throws {
        self.configuration = configuration
        self.maximumBytes = maximumBytes
        self.limitKind = limitKind
        self.destination = destination
        super.init()

        if case let .file(url) = destination {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                fileHandle = try FileHandle(forWritingTo: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    func start(request: URLRequest) async throws -> BoundedTransferResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = Task.isCancelled
                lock.withLock {
                    self.continuation = continuation
                    if alreadyCancelled, terminalError == nil {
                        terminalError = CancellationError()
                    }
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    let session = URLSession(
                        configuration: configuration,
                        delegate: self,
                        delegateQueue: queue
                    )
                    let task = session.dataTask(with: request)
                    self.session = session
                    self.task = task
                    task.resume()
                    if terminalError != nil {
                        task.cancel()
                    }
                }
            }
        } onCancel: {
            self.cancel(with: CancellationError())
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock {
                terminalError = CasaOSError.invalidResponse
            }
            completionHandler(.cancel)
            return
        }

        let shouldCancel = lock.withLock {
            self.response = http
            guard (200...299).contains(http.statusCode),
                  http.expectedContentLength >= 0,
                  http.expectedContentLength > maximumBytes else {
                return false
            }
            terminalError = transferLimitError(kind: limitKind, bytes: maximumBytes)
            return true
        }
        completionHandler(shouldCancel ? .cancel : .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var shouldCancel = false
        lock.withLock {
            guard terminalError == nil, let response else { return }

            if !(200...299).contains(response.statusCode) {
                let remaining = max(0, 64 * 1_024 - errorBody.count)
                errorBody.append(data.prefix(remaining))
                if data.count > remaining || errorBody.count == 64 * 1_024 {
                    cancelledAfterErrorBodyLimit = true
                    shouldCancel = true
                }
                return
            }

            guard Int64(data.count) <= maximumBytes - receivedBytes else {
                terminalError = transferLimitError(kind: limitKind, bytes: maximumBytes)
                shouldCancel = true
                return
            }
            receivedBytes += Int64(data.count)

            do {
                switch destination {
                case .memory:
                    memoryData.append(data)
                case .file:
                    try fileHandle?.write(contentsOf: data)
                }
            } catch {
                terminalError = error
                shouldCancel = true
            }
        }
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        finish(networkError: error)
    }

    private func cancel(with error: any Error) {
        let task = lock.withLock {
            guard !completed else { return nil as URLSessionDataTask? }
            if terminalError == nil {
                terminalError = error
            }
            return self.task
        }
        task?.cancel()
    }

    private func finish(networkError: (any Error)?) {
        let outcome: Result<BoundedTransferResponse, any Error>? = lock.withLock {
            guard !completed else { return nil }
            completed = true

            if let terminalError {
                return .failure(terminalError)
            }
            if let networkError, !cancelledAfterErrorBodyLimit {
                return .failure(networkError)
            }
            guard let response else {
                return .failure(CasaOSError.invalidResponse)
            }
            if (200...299).contains(response.statusCode) {
                let fileURL: URL?
                if case let .file(url) = destination {
                    fileURL = url
                } else {
                    fileURL = nil
                }
                return .success(BoundedTransferResponse(
                    statusCode: response.statusCode,
                    data: memoryData,
                    fileURL: fileURL
                ))
            }
            return .success(BoundedTransferResponse(
                statusCode: response.statusCode,
                data: errorBody,
                fileURL: nil
            ))
        }
        guard let outcome else { return }

        let continuation = lock.withLock { () -> CheckedContinuation<BoundedTransferResponse, any Error>? in
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        try? fileHandle?.close()
        fileHandle = nil

        if case .failure = outcome {
            removePartialFile()
        } else if case let .success(response) = outcome, response.fileURL == nil {
            removePartialFile()
        }

        continuation?.resume(with: outcome)
        let session = lock.withLock { () -> URLSession? in
            let session = self.session
            self.session = nil
            self.task = nil
            return session
        }
        session?.finishTasksAndInvalidate()
    }

    private func removePartialFile() {
        guard case let .file(url) = destination else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

actor HTTPCasaOSClient: CasaOSClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: any SessionTokenStore
    private let fileTransferLimits: CasaFileTransferLimits
    private var tokens: SessionTokens?
    private var cachedServerMetadata: ServerMetadata?

    init(
        baseURL: URL,
        tokenStore: any SessionTokenStore = KeychainStore(),
        session: URLSession? = nil,
        fileTransferLimits: CasaFileTransferLimits = .production
    ) {
        self.baseURL = baseURL
        self.tokenStore = tokenStore
        self.fileTransferLimits = fileTransferLimits

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func verifyServer() async throws {
        let data = try await perform(
            path: "/v1/users/status",
            authenticated: false,
            retryOnUnauthorized: false
        )
        let response: V1Envelope<UserStatusData> = try decode(data)
        try validate(response)
    }

    func restoreSession() async throws -> Bool {
        tokens = try await tokenStore.load(for: baseURL)
        return tokens != nil
    }

    func validateSession() async throws {
        _ = try await perform(path: "/v1/sys/version/current")
    }

    func login(username: String, password: String) async throws {
        let body = LoginRequest(username: username, password: password)
        let data = try await perform(
            path: "/v1/users/login",
            method: "POST",
            body: try encode(body),
            authenticated: false,
            retryOnUnauthorized: false
        )
        let response: V1Envelope<LoginData> = try decode(data)
        try validate(response)
        let newTokens = response.data.token.sessionTokens
        try await tokenStore.store(newTokens, for: baseURL)
        tokens = newTokens
    }

    func logout() async {
        tokens = nil
        try? await tokenStore.delete(for: baseURL)
    }

    func fetchServerSummary() async throws -> ServerSummary {
        async let utilizationData = perform(path: "/v1/sys/utilization")

        let metadata = try await serverMetadata()
        let utilization: V1Envelope<UtilizationData> = try decode(try await utilizationData)
        try validate(utilization)

        let disk = utilization.data.systemDisk
        let diskPercent: Double?
        if let size = disk?.size, size > 0, let used = disk?.used {
            diskPercent = Double(used) / Double(size) * 100
        } else {
            diskPercent = nil
        }

        return ServerSummary(
            name: "CasaOS",
            version: metadata.version,
            status: .online,
            model: metadata.model,
            architecture: metadata.architecture,
            cpuPercent: utilization.data.cpu.percent,
            memoryPercent: utilization.data.memory.usedPercent,
            memoryUsed: utilization.data.memory.used,
            memoryTotal: utilization.data.memory.total,
            diskPercent: diskPercent,
            diskUsed: disk?.used,
            diskFree: disk?.available,
            diskTotal: disk?.size,
            temperature: utilization.data.cpu.temperature
        )
    }

    func fetchStorageDrives() async throws -> [StorageDrive] {
        let data = try await perform(path: "/v1/storage")
        let response: V1Envelope<[StorageDiskData]> = try decode(data)
        try validate(response)

        return groupedStorageDrives(response.data.compactMap {
            storageDrive(from: $0, category: .nonSystem)
        })
            .sorted {
                if $0.name.localizedStandardCompare($1.name) == .orderedSame {
                    return $0.id < $1.id
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func fetchSystemDrives() async throws -> [StorageDrive] {
        let data = try await perform(
            path: "/v1/storage",
            query: ["system": "true"]
        )
        let response: V1Envelope<[StorageDiskData]> = try decode(data)
        try validate(response)

        return groupedStorageDrives(response.data.compactMap {
            storageDrive(from: $0, category: .system)
        })
            .sorted {
                if $0.name.localizedStandardCompare($1.name) == .orderedSame {
                    return $0.id < $1.id
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func fetchDriveHealth(devicePath: String) async throws -> PhysicalDriveHealth {
        let requestedPath = devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedPath.isEmpty else {
            throw CasaOSError.contract("A physical drive path is required.")
        }

        let data = try await perform(path: "/v1/disks")
        let response: V1Envelope<PhysicalDiskListData> = try decode(data)
        try validate(response)

        let exactMatch = response.data.disks.first {
            nonempty($0.path) == requestedPath
        }
        let requestedName = (requestedPath as NSString).lastPathComponent
        let fallbackMatches = response.data.disks.filter { disk in
            let pathName = nonempty(disk.path).map { ($0 as NSString).lastPathComponent }
            return pathName?.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
                || nonempty(disk.name)?.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
        }
        guard let disk = exactMatch ?? (fallbackMatches.count == 1 ? fallbackMatches[0] : nil) else {
            return PhysicalDriveHealth(
                devicePath: requestedPath,
                name: requestedName,
                model: nil,
                serialNumber: nil,
                diskType: nil,
                capacityBytes: nil,
                status: .unavailable,
                temperatureCelsius: nil
            )
        }

        let fallbackName = requestedName
        let temperature = disk.temperature.flatMap { $0 > 0 ? Double($0) : nil }
        let status: PhysicalDriveHealth.Status = switch disk.health?.value {
        case true:
            .reportedHealthy
        case false:
            .attentionRequired
        case nil:
            .unavailable
        }

        return PhysicalDriveHealth(
            devicePath: requestedPath,
            name: nonempty(disk.model) ?? nonempty(disk.name) ?? fallbackName,
            model: nonempty(disk.model),
            serialNumber: nonempty(disk.serial),
            diskType: nonempty(disk.diskType),
            capacityBytes: disk.size.flatMap(signedByteCount),
            status: status,
            temperatureCelsius: temperature
        )
    }

    func fetchApps() async throws -> [CasaApp] {
        let data = try await perform(path: "/v2/app_management/compose")
        let response: V2Envelope<[String: ComposeAppData]> = try decode(data)
        return response.data.map { id, app in
            let localizedTitle = app.storeInfo?.title?["en_us"]
                ?? app.storeInfo?.title?.values.first
            let title = nonempty(localizedTitle)
                ?? nonempty(id)
                ?? nonempty(app.compose?.name)
                ?? "App"
            return CasaApp(
                id: id,
                name: title,
                status: app.status ?? "unknown",
                iconURL: app.storeInfo?.icon.flatMap(URL.init(string:)),
                scheme: app.storeInfo?.scheme,
                hostname: app.storeInfo?.hostname,
                port: app.storeInfo?.portMap,
                path: app.storeInfo?.index,
                appType: "v2app"
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setAppStatus(_ status: AppAction, appID: String) async throws {
        _ = try await perform(
            path: "/v2/app_management/compose/\(appID)/status",
            method: "PUT",
            body: try encode(status.rawValue)
        )
    }

    func listFiles(at path: String) async throws -> [CasaFile] {
        let data = try await perform(path: "/v1/folder", query: ["path": path])
        let response: V1Envelope<FileListData> = try decode(data)
        try validate(response)
        return response.data.content.map {
            CasaFile(
                name: $0.name,
                path: $0.path,
                isDirectory: $0.isDirectory,
                size: $0.size,
                modified: $0.modified ?? $0.date
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func createFolder(at path: String) async throws {
        guard let path = CasaFilePathPolicy.normalizedMutableItem(path) else {
            throw CasaOSError.contract("Casa Native only creates folders at safe absolute paths.")
        }
        let data = try await perform(
            path: "/v1/folder",
            method: "POST",
            body: try encode(["path": path])
        )
        let response: V1Envelope<EmptyData?> = try decode(data)
        try validate(response)
    }

    func uploadFile(data: Data, named name: String, to directory: String) async throws {
        guard Int64(data.count) <= fileTransferLimits.uploadBytes else {
            throw transferLimitError(
                kind: "in-memory transfer",
                bytes: fileTransferLimits.uploadBytes
            )
        }
        guard let directory = CasaFilePathPolicy.normalizedUploadDirectory(
            directory,
            filename: name
        ) else {
            throw CasaOSError.contract("Casa Native only uploads files to safe absolute paths.")
        }
        let boundary = "CasaNative-\(UUID().uuidString)"
        let fields = [
            "path": directory,
            "relativePath": name,
            "filename": name,
            "totalChunks": "1",
            "chunkNumber": "1",
            "chunkSize": String(data.count),
            "currentChunkSize": String(data.count),
            "totalSize": String(data.count),
            "identifier": "\(UUID().uuidString)-\(name)",
        ]
        let body = MultipartFormData(boundary: boundary)
            .adding(fields: fields)
            .addingFile(data: data, name: "file", filename: name)
            .encoded()
        _ = try await perform(
            path: "/v2/casaos/file/upload",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    func downloadFile(at path: String) async throws -> Data {
        try await downloadData(
            path: "/v1/file",
            query: ["path": path],
            maximumBytes: fileTransferLimits.inMemoryBytes
        )
    }

    func renameItem(
        at sourcePath: String,
        to destinationPath: String,
        isDirectory: Bool
    ) async throws {
        guard let paths = CasaFilePathPolicy.normalizedRename(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            isDirectory: isDirectory
        ) else {
            throw CasaOSError.contract("Casa Native only renames items using safe absolute paths.")
        }
        let data = try await perform(
            path: isDirectory ? "/v1/folder/name" : "/v1/file/name",
            method: "PUT",
            body: try encode(RenameItemRequest(
                oldPath: paths.source,
                newPath: paths.destination
            ))
        )
        let response: V1StatusEnvelope = try decode(data)
        try validate(response)
    }

    func transferItems(
        at sourcePaths: [String],
        to destinationDirectory: String,
        operation: CasaFileOperation,
        collisionPolicy: CasaFileCollisionPolicy
    ) async throws {
        guard let transfer = CasaFilePathPolicy.normalizedTransfer(
            sourcePaths: sourcePaths,
            destinationDirectory: destinationDirectory
        ) else {
            throw CasaOSError.contract("Casa Native only transfers items using safe absolute paths.")
        }
        let data = try await perform(
            path: "/v1/batch/task",
            method: "POST",
            body: try encode(TransferItemsRequest(
                type: operation,
                item: transfer.sources.map(TransferItemRequest.init(from:)),
                to: transfer.destination,
                style: collisionPolicy
            ))
        )
        let response: V1StatusEnvelope = try decode(data)
        try validate(response)
    }

    func prepareFileForPreview(at path: String, named filename: String) async throws -> URL {
        guard let preview = CasaFilePathPolicy.normalizedPreview(path: path, filename: filename) else {
            throw CasaOSError.contract("Casa Native only previews safe absolute file paths.")
        }
        let downloadedURL = try await download(
            path: "/v1/file",
            query: ["path": preview.path],
            maximumBytes: fileTransferLimits.previewBytes
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CasaNativePreview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(
                preview.filename,
                isDirectory: false
            )
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: downloadedURL)
            throw error
        }
    }

    func prepareFileForThumbnail(at path: String, named filename: String) async throws -> URL {
        guard let thumbnail = CasaFilePathPolicy.normalizedPreview(path: path, filename: filename) else {
            throw CasaOSError.contract(
                "Casa Native only prepares thumbnails for safe absolute file paths."
            )
        }
        try Task.checkCancellation()

        var downloadedURL: URL?
        var thumbnailDirectory: URL?
        do {
            let transportURL = try await download(
                path: "/v1/file",
                query: ["path": thumbnail.path],
                maximumBytes: fileTransferLimits.thumbnailBytes,
                limitKind: "thumbnail"
            )
            downloadedURL = transportURL
            try Task.checkCancellation()

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CasaNativeThumbnail-\(UUID().uuidString)",
                    isDirectory: true
                )
            thumbnailDirectory = directory
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Task.checkCancellation()

            let destination = directory.appendingPathComponent(
                thumbnail.filename,
                isDirectory: false
            )
            try FileManager.default.moveItem(at: transportURL, to: destination)
            downloadedURL = nil
            try Task.checkCancellation()
            return destination
        } catch {
            if let thumbnailDirectory {
                try? FileManager.default.removeItem(at: thumbnailDirectory)
            }
            if let downloadedURL {
                try? FileManager.default.removeItem(at: downloadedURL)
            }
            throw error
        }
    }

    func deleteFiles(at paths: [String]) async throws {
        let normalizedPaths = paths.compactMap(CasaFilePathPolicy.normalizedMutableItem)
        guard !paths.isEmpty, normalizedPaths.count == paths.count else {
            throw CasaOSError.contract("Casa Native only deletes items using safe absolute paths.")
        }
        let data = try await perform(
            path: "/v1/batch",
            method: "DELETE",
            body: try encode(normalizedPaths)
        )
        let response: V1Envelope<EmptyData?> = try decode(data)
        try validate(response)
    }

    func setPowerState(_ state: PowerState) async throws {
        _ = try await perform(path: "/v1/sys/state/\(state.rawValue)", method: "PUT")
    }

    private func serverMetadata() async throws -> ServerMetadata {
        if let cachedServerMetadata {
            return cachedServerMetadata
        }

        async let versionData = perform(
            path: "/v1/sys/version/current",
            authenticated: false
        )
        async let hardwareData = perform(path: "/v1/sys/hardware")

        let version = String(decoding: try await versionData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hardware: V1Envelope<HardwareData> = try decode(try await hardwareData)
        try validate(hardware)

        let metadata = ServerMetadata(
            version: version.isEmpty ? "Unknown" : version,
            model: nonempty(hardware.data.driveModel),
            architecture: nonempty(hardware.data.architecture)
        )
        cachedServerMetadata = metadata
        return metadata
    }

    private func storageDrive(
        from disk: StorageDiskData,
        category: StorageDriveCategory
    ) -> StorageDriveCandidate? {
        let children = disk.children ?? []
        let diskName = disk.diskName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSystemDisk = diskName?.localizedCaseInsensitiveCompare("System") == .orderedSame
            || children.contains {
                isOSMountPoint($0.mountPoint)
                    || $0.label?.localizedCaseInsensitiveCompare("System") == .orderedSame
            }
        guard isSystemDisk == (category == .system) else { return nil }

        let volumes = children.filter {
            $0.type?.localizedCaseInsensitiveCompare("swap") != .orderedSame
                && (category == .system
                    ? isOSMountPoint($0.mountPoint)
                    : !isOSMountPoint($0.mountPoint))
        }
        let mountPointSet: Set<String> = Set(volumes.compactMap { volume in
            let value = volume.mountPoint?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        })
        let mountPoints = mountPointSet.sorted { (lhs: String, rhs: String) in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        guard !mountPoints.isEmpty else { return nil }

        let devicePath = disk.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let labels = volumes.compactMap { volume -> String? in
            let label = volume.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return label?.isEmpty == false ? label : nil
        }
        let fallbackDeviceName = (devicePath as NSString).lastPathComponent
        let name = labels.count == 1
            ? labels[0]
            : nonempty(diskName) ?? nonempty(labels.first) ?? nonempty(fallbackDeviceName) ?? "Drive"
        let totalBytes = sumBytes(volumes.map(\.size))
            ?? disk.size.flatMap(signedByteCount)
        let logicalChildPaths = Array(Set(volumes.compactMap { volume -> String? in
            guard let path = nonempty(volume.path) else { return nil }
            return (path as NSString).standardizingPath
        }))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let uuidMountPoints = Array(Set(volumes.compactMap { volume -> StorageUUIDMountPoint? in
            guard let uuid = nonempty(volume.uuid),
                  let mountPoint = nonempty(volume.mountPoint)
            else { return nil }
            return StorageUUIDMountPoint(
                uuid: uuid.lowercased(),
                mountPoint: (mountPoint as NSString).standardizingPath
            )
        }))
        .sorted {
            if $0.mountPoint == $1.mountPoint {
                return $0.uuid < $1.uuid
            }
            return $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending
        }

        return StorageDriveCandidate(
            drive: StorageDrive(
                id: nonempty(devicePath) ?? mountPoints.joined(separator: "|"),
                name: name,
                devicePaths: nonempty(devicePath).map { [$0] } ?? [],
                mountPoints: mountPoints,
                totalBytes: totalBytes,
                usedBytes: sumBytes(volumes.map(\.used)),
                freeBytes: sumBytes(volumes.map(\.available))
            ),
            logicalChildPaths: logicalChildPaths,
            uuidMountPoints: uuidMountPoints
        )
    }

    private func groupedStorageDrives(_ candidates: [StorageDriveCandidate]) -> [StorageDrive] {
        var grouped: [StorageDrive] = []
        var indexByFilesystem: [StorageFilesystemKey: Int] = [:]

        for candidate in candidates.sorted(by: { $0.drive.id < $1.drive.id }) {
            let drive = candidate.drive
            let keys = StorageFilesystemKey.keys(for: candidate)
            let existingIndex = keys.lazy.compactMap { indexByFilesystem[$0] }.first
            if let index = existingIndex {
                let existing = grouped[index]
                grouped[index] = StorageDrive(
                    id: existing.id,
                    name: existing.name,
                    devicePaths: Array(Set(existing.devicePaths + drive.devicePaths))
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                    mountPoints: existing.mountPoints,
                    totalBytes: existing.totalBytes,
                    usedBytes: existing.usedBytes,
                    freeBytes: existing.freeBytes
                )
                for key in keys where indexByFilesystem[key] == nil {
                    indexByFilesystem[key] = index
                }
            } else {
                let index = grouped.count
                for key in keys {
                    indexByFilesystem[key] = index
                }
                grouped.append(StorageDrive(
                    id: drive.id,
                    name: drive.name,
                    devicePaths: drive.devicePaths,
                    mountPoints: drive.mountPoints,
                    totalBytes: drive.totalBytes,
                    usedBytes: drive.usedBytes,
                    freeBytes: drive.freeBytes
                ))
            }
        }
        return grouped
    }

    private func isOSMountPoint(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let normalized = (value as NSString).standardizingPath
        return normalized == "/"
            || normalized == "/boot"
            || normalized.hasPrefix("/boot/")
    }

    private func sumBytes(_ values: [String?]) -> Int64? {
        guard !values.isEmpty else { return nil }
        var total: Int64 = 0
        for value in values {
            guard let value, let bytes = Int64(value), bytes >= 0 else { return nil }
            let result = total.addingReportingOverflow(bytes)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private func signedByteCount(_ value: UInt64) -> Int64? {
        guard value <= UInt64(Int64.max) else { return nil }
        return Int64(value)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutControls = String(
            value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        )
        let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func perform(
        path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: Data? = nil,
        contentType: String = "application/json",
        authenticated: Bool = true,
        retryOnUnauthorized: Bool = true
    ) async throws -> Data {
        if authenticated, tokens == nil {
            _ = try await restoreSession()
        }
        if authenticated, tokens == nil {
            throw CasaOSError.noSession
        }

        let request = try makeRequest(
            path: path,
            method: method,
            query: query,
            body: body,
            contentType: contentType,
            token: authenticated ? tokens?.accessToken : nil
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CasaOSError.invalidResponse
        }

        if http.statusCode == 401, authenticated {
            if retryOnUnauthorized, try await refreshSession() {
                return try await perform(
                    path: path,
                    method: method,
                    query: query,
                    body: body,
                    contentType: contentType,
                    authenticated: authenticated,
                    retryOnUnauthorized: false
                )
            }
            tokens = nil
            try? await tokenStore.delete(for: baseURL)
            throw CasaOSError.unauthorized
        }

        guard (200...299).contains(http.statusCode) else {
            throw CasaOSError.server(
                status: http.statusCode,
                message: serverMessage(from: data)
            )
        }
        return data
    }

    private func downloadData(
        path: String,
        query: [String: String],
        maximumBytes: Int64,
        retryOnUnauthorized: Bool = true
    ) async throws -> Data {
        if tokens == nil {
            _ = try await restoreSession()
        }
        guard let tokens else { throw CasaOSError.noSession }

        let request = try makeRequest(
            path: path,
            method: "GET",
            query: query,
            body: nil,
            contentType: "application/json",
            token: tokens.accessToken
        )
        let transfer = try BoundedURLSessionTransfer(
            configuration: session.configuration,
            maximumBytes: maximumBytes,
            limitKind: "in-memory download",
            destination: .memory
        )
        let response = try await transfer.start(request: request)

        if response.statusCode == 401 {
            if retryOnUnauthorized, try await refreshSession() {
                return try await downloadData(
                    path: path,
                    query: query,
                    maximumBytes: maximumBytes,
                    retryOnUnauthorized: false
                )
            }
            self.tokens = nil
            try? await tokenStore.delete(for: baseURL)
            throw CasaOSError.unauthorized
        }

        guard (200...299).contains(response.statusCode) else {
            throw CasaOSError.server(
                status: response.statusCode,
                message: serverMessage(from: response.data)
            )
        }
        return response.data
    }

    private func download(
        path: String,
        query: [String: String],
        maximumBytes: Int64,
        limitKind: String = "preview",
        retryOnUnauthorized: Bool = true
    ) async throws -> URL {
        if tokens == nil {
            _ = try await restoreSession()
        }
        guard let tokens else { throw CasaOSError.noSession }

        let request = try makeRequest(
            path: path,
            method: "GET",
            query: query,
            body: nil,
            contentType: "application/json",
            token: tokens.accessToken
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CasaNativeTransport-\(UUID().uuidString)", isDirectory: false)
        let transfer = try BoundedURLSessionTransfer(
            configuration: session.configuration,
            maximumBytes: maximumBytes,
            limitKind: limitKind,
            destination: .file(temporaryURL)
        )
        let response = try await transfer.start(request: request)

        if response.statusCode == 401 {
            if retryOnUnauthorized, try await refreshSession() {
                return try await download(
                    path: path,
                    query: query,
                    maximumBytes: maximumBytes,
                    limitKind: limitKind,
                    retryOnUnauthorized: false
                )
            }
            self.tokens = nil
            try? await tokenStore.delete(for: baseURL)
            throw CasaOSError.unauthorized
        }

        guard (200...299).contains(response.statusCode) else {
            throw CasaOSError.server(
                status: response.statusCode,
                message: serverMessage(from: response.data)
            )
        }
        guard let fileURL = response.fileURL else {
            throw CasaOSError.invalidResponse
        }
        return fileURL
    }

    private func refreshSession() async throws -> Bool {
        guard let refreshToken = tokens?.refreshToken, !refreshToken.isEmpty else {
            return false
        }
        let data = try await perform(
            path: "/v1/users/refresh",
            method: "POST",
            body: try encode(["refresh_token": refreshToken]),
            authenticated: false,
            retryOnUnauthorized: false
        )
        let response: V1Envelope<TokenPayload> = try decode(data)
        try validate(response)
        let newTokens = response.data.sessionTokens
        try await tokenStore.store(newTokens, for: baseURL)
        tokens = newTokens
        return true
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [String: String],
        body: Data?,
        contentType: String,
        token: String?
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        ) else {
            throw CasaOSError.invalidEndpoint
        }
        if !query.isEmpty {
            components.queryItems = query.sorted(by: { $0.key < $1.key }).map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }
        guard let url = components.url else { throw CasaOSError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("en_us", forHTTPHeaderField: "Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CasaOSError.contract("CasaOS response did not match the expected API contract.")
        }
    }

    private func validate<T>(_ response: V1Envelope<T>) throws {
        guard response.success == 200 else {
            throw CasaOSError.server(status: response.success, message: response.message)
        }
    }

    private func validate(_ response: V1StatusEnvelope) throws {
        guard response.success == 200 else {
            throw CasaOSError.server(status: response.success, message: response.message)
        }
    }

    private func serverMessage(from data: Data) -> String {
        (try? JSONDecoder().decode(ErrorPayload.self, from: data).message)
            ?? String(data: data, encoding: .utf8)
            ?? ""
    }
}

private struct LoginRequest: Encodable, Sendable {
    let username: String
    let password: String
}

private struct RenameItemRequest: Encodable, Sendable {
    let oldPath: String
    let newPath: String

    enum CodingKeys: String, CodingKey {
        case oldPath = "old_path"
        case newPath = "new_path"
    }
}

private struct TransferItemsRequest: Encodable, Sendable {
    let type: CasaFileOperation
    let item: [TransferItemRequest]
    let to: String
    let style: CasaFileCollisionPolicy
}

private struct TransferItemRequest: Encodable, Sendable {
    let from: String
}

private struct V1Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Int
    let message: String
    let data: T
}

private struct V1StatusEnvelope: Decodable, Sendable {
    let success: Int
    let message: String
}

private struct V2Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    let data: T
}

private struct EmptyData: Decodable, Sendable {}

private struct UserStatusData: Decodable, Sendable {
    let initialized: Bool
}

private struct LoginData: Decodable, Sendable {
    let token: TokenPayload
}

private struct TokenPayload: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }

    var sessionTokens: SessionTokens {
        SessionTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private struct HardwareData: Decodable, Sendable {
    let driveModel: String?
    let architecture: String?

    enum CodingKeys: String, CodingKey {
        case driveModel = "drive_model"
        case architecture = "arch"
    }
}

private struct ServerMetadata: Sendable {
    let version: String
    let model: String?
    let architecture: String?
}

private struct StorageDriveCandidate {
    let drive: StorageDrive
    let logicalChildPaths: [String]
    let uuidMountPoints: [StorageUUIDMountPoint]
}

private enum StorageDriveCategory {
    case system
    case nonSystem
}

private struct StorageUUIDMountPoint: Hashable {
    let uuid: String
    let mountPoint: String
}

private enum StorageFilesystemKey: Hashable {
    case logicalChildPaths([String])
    case uuidMountPoints([StorageUUIDMountPoint])
    case mountedUsage(
        mountPoints: [String],
        totalBytes: Int64?,
        usedBytes: Int64?,
        freeBytes: Int64?
    )

    static func keys(for candidate: StorageDriveCandidate) -> [Self] {
        var keys: [Self] = []
        if !candidate.logicalChildPaths.isEmpty {
            keys.append(.logicalChildPaths(candidate.logicalChildPaths))
        }
        if !candidate.uuidMountPoints.isEmpty {
            keys.append(.uuidMountPoints(candidate.uuidMountPoints))
        }
        if keys.isEmpty {
            let drive = candidate.drive
            keys.append(.mountedUsage(
                mountPoints: drive.mountPoints,
                totalBytes: drive.totalBytes,
                usedBytes: drive.usedBytes,
                freeBytes: drive.freeBytes
            ))
        }
        return keys
    }
}

private struct UtilizationData: Decodable, Sendable {
    let cpu: CPUData
    let memory: MemoryData
    let systemDisk: DiskData?

    enum CodingKeys: String, CodingKey {
        case cpu
        case memory = "mem"
        case systemDisk = "sys_disk"
    }
}

private struct CPUData: Decodable, Sendable {
    let percent: Double?
    let temperature: Double?
}

private struct MemoryData: Decodable, Sendable {
    let total: Int64?
    let used: Int64?
    let usedPercent: Double?
}

private struct DiskData: Decodable, Sendable {
    let size: Int64?
    let used: Int64?
    let available: Int64?

    enum CodingKeys: String, CodingKey {
        case size, used
        case available = "avail"
    }
}

private struct StorageDiskData: Decodable, Sendable {
    let diskName: String?
    let size: UInt64?
    let path: String?
    let children: [StorageVolumeData]?

    enum CodingKeys: String, CodingKey {
        case diskName = "disk_name"
        case size, path, children
    }
}

private struct StorageVolumeData: Decodable, Sendable {
    let path: String?
    let uuid: String?
    let mountPoint: String?
    let size: String?
    let available: String?
    let used: String?
    let type: String?
    let label: String?

    enum CodingKeys: String, CodingKey {
        case path, uuid
        case mountPoint = "mount_point"
        case size
        case available = "avail"
        case used, type, label
    }
}

private struct PhysicalDiskListData: Decodable, Sendable {
    let disks: [PhysicalDiskData]
}

private struct PhysicalDiskData: Decodable, Sendable {
    let name: String?
    let size: UInt64?
    let model: String?
    let health: ReportedHealthData?
    let temperature: Int?
    let diskType: String?
    let serial: String?
    let path: String?

    enum CodingKeys: String, CodingKey {
        case name, size, model, health, temperature, serial, path
        case diskType = "disk_type"
    }
}

private struct ReportedHealthData: Decodable, Sendable {
    let value: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let string = try? container.decode(String.self) {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "healthy", "ok":
                value = true
            case "false", "0", "failing", "failed":
                value = false
            default:
                value = nil
            }
        } else if let integer = try? container.decode(Int.self) {
            value = integer == 1 ? true : integer == 0 ? false : nil
        } else {
            value = nil
        }
    }
}

private struct ComposeAppData: Decodable, Sendable {
    let storeInfo: StoreInfoData?
    let compose: ComposeData?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case storeInfo = "store_info"
        case compose
        case status
    }
}

private struct StoreInfoData: Decodable, Sendable {
    let title: [String: String]?
    let icon: String?
    let scheme: String?
    let hostname: String?
    let portMap: String?
    let index: String?

    enum CodingKeys: String, CodingKey {
        case title, icon, scheme, hostname, index
        case portMap = "port_map"
    }
}

private struct ComposeData: Decodable, Sendable {
    let name: String?
}

private struct FileListData: Decodable, Sendable {
    let content: [FileData]
}

private struct FileData: Decodable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let date: Date?

    enum CodingKeys: String, CodingKey {
        case name, path, size, modified, date
        case isDirectory = "is_dir"
    }
}

private struct ErrorPayload: Decodable, Sendable {
    let message: String
}

private struct MultipartFormData {
    let boundary: String
    private var chunks: [Data] = []

    init(boundary: String) {
        self.boundary = boundary
    }

    func adding(fields: [String: String]) -> Self {
        var copy = self
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            let escapedKey = Self.escapedQuotedHeaderParameter(key)
            copy.chunks.append(Data("--\(boundary)\r\n".utf8))
            copy.chunks.append(Data("Content-Disposition: form-data; name=\"\(escapedKey)\"\r\n\r\n".utf8))
            copy.chunks.append(Data("\(value)\r\n".utf8))
        }
        return copy
    }

    func addingFile(data: Data, name: String, filename: String) -> Self {
        var copy = self
        let escapedName = Self.escapedQuotedHeaderParameter(name)
        let escapedFilename = Self.escapedQuotedHeaderParameter(filename)
        copy.chunks.append(Data("--\(boundary)\r\n".utf8))
        copy.chunks.append(Data("Content-Disposition: form-data; name=\"\(escapedName)\"; filename=\"\(escapedFilename)\"\r\n".utf8))
        copy.chunks.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        copy.chunks.append(data)
        copy.chunks.append(Data("\r\n".utf8))
        return copy
    }

    func encoded() -> Data {
        var result = Data()
        for chunk in chunks { result.append(chunk) }
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private static func escapedQuotedHeaderParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
