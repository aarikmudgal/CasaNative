import Foundation

protocol CasaOSClient: Sendable {
    func restoreSession() async throws -> Bool
    func validateSession() async throws
    func login(username: String, password: String) async throws
    func logout() async
    func fetchServerSummary() async throws -> ServerSummary
    func fetchStorageDrives() async throws -> [StorageDrive]
    func fetchSystemDrives() async throws -> [StorageDrive]
    func fetchDriveHealth(devicePath: String) async throws -> PhysicalDriveHealth
    func fetchApps() async throws -> [CasaApp]
    func setAppStatus(_ status: AppAction, appID: String) async throws
    func listFiles(at path: String) async throws -> [CasaFile]
    func createFolder(at path: String) async throws
    func uploadFile(data: Data, named name: String, to directory: String) async throws
    func downloadFile(at path: String) async throws -> Data
    func renameItem(
        at sourcePath: String,
        to destinationPath: String,
        isDirectory: Bool
    ) async throws
    func transferItems(
        at sourcePaths: [String],
        to destinationDirectory: String,
        operation: CasaFileOperation,
        collisionPolicy: CasaFileCollisionPolicy
    ) async throws
    func prepareFileForPreview(at path: String, named filename: String) async throws -> URL
    func prepareFileForThumbnail(at path: String, named filename: String) async throws -> URL
    func deleteFiles(at paths: [String]) async throws
    func setPowerState(_ state: PowerState) async throws
}

struct ServerSummary: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case online = "Online"
        case offline = "Offline"
    }

    let name: String
    let version: String
    let status: Status
    var model: String? = nil
    var architecture: String? = nil
    var cpuPercent: Double? = nil
    var memoryPercent: Double? = nil
    var memoryUsed: Int64? = nil
    var memoryTotal: Int64? = nil
    var diskPercent: Double? = nil
    var diskUsed: Int64? = nil
    var diskFree: Int64? = nil
    var diskTotal: Int64? = nil
    var temperature: Double? = nil
}

struct StorageDrive: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let devicePaths: [String]
    let mountPoints: [String]
    let totalBytes: Int64?
    let usedBytes: Int64?
    let freeBytes: Int64?

    var usedPercent: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    var isRAIDCluster: Bool {
        devicePaths.count > 1
    }
}

struct PhysicalDriveHealth: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case reportedHealthy
        case attentionRequired
        case unavailable
    }

    var id: String { devicePath }

    let devicePath: String
    let name: String
    let model: String?
    let serialNumber: String?
    let diskType: String?
    let capacityBytes: Int64?
    let status: Status
    let temperatureCelsius: Double?
}

struct CasaApp: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: String
    let iconURL: URL?
    let scheme: String?
    let hostname: String?
    let port: String?
    let path: String?
    let appType: String

    var isRunning: Bool {
        status.localizedCaseInsensitiveContains("running")
    }

    func launchURL(relativeTo serverURL: URL) -> URL? {
        var components = URLComponents()
        let activeScheme = serverURL.scheme?.lowercased()
        let advertisedScheme = scheme?.lowercased()
        if activeScheme == "https" {
            components.scheme = "https"
        } else if advertisedScheme == "http" || advertisedScheme == "https" {
            components.scheme = advertisedScheme
        } else {
            components.scheme = activeScheme
        }
        // Keep the route that successfully reached CasaOS. Store metadata often
        // contains a LAN-only hostname that is unreachable through Tailscale.
        components.host = serverURL.host

        if let port, let value = Int(port), value > 0 {
            components.port = value
        } else {
            components.port = serverURL.port
        }

        if let path, !path.isEmpty {
            components.path = path.hasPrefix("/") ? path : "/\(path)"
        }
        return components.url
    }
}

enum AppAction: String, CaseIterable, Sendable {
    case start
    case stop
    case restart
}

struct CasaFile: Identifiable, Equatable, Sendable {
    static let serverRootPath = "/"
    static let rootPath = "/DATA"

    var id: String { path }

    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
}

enum CasaFileOperation: String, Codable, Sendable {
    case copy
    case move
}

enum CasaFileCollisionPolicy: String, Codable, Sendable {
    case skip
    case overwrite
}

enum CasaFilePathPolicy {
    static func normalizedAbsolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/"),
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              !hasTraversalComponent(path) else {
            return nil
        }

        let normalized = (path as NSString).standardizingPath
        return normalized.hasPrefix("/") ? normalized : nil
    }

    static func isWritableDirectory(_ path: String) -> Bool {
        normalizedAbsolutePath(path) != nil
    }

    static func normalizedMutableItem(_ path: String) -> String? {
        guard let normalized = normalizedAbsolutePath(path),
              normalized != CasaFile.serverRootPath else {
            return nil
        }
        return normalized
    }

    static func normalizedUploadDirectory(_ directory: String, filename: String) -> String? {
        guard isSafeFilename(filename),
              let normalizedDirectory = normalizedAbsolutePath(directory),
              isWritableDirectory(normalizedDirectory) else {
            return nil
        }

        let target = (normalizedDirectory as NSString).appendingPathComponent(filename)
        return normalizedMutableItem(target) == nil ? nil : normalizedDirectory
    }

    static func normalizedRename(
        sourcePath: String,
        destinationPath: String,
        isDirectory: Bool
    ) -> (source: String, destination: String)? {
        guard let source = normalizedMutableItem(sourcePath),
              let destination = normalizedMutableItem(destinationPath),
              source != destination,
              parent(of: source) == parent(of: destination),
              (!isDirectory || !isSameOrDescendant(destination, of: source)) else {
            return nil
        }
        return (source, destination)
    }

    static func normalizedTransfer(
        sourcePaths: [String],
        destinationDirectory: String
    ) -> (sources: [String], destination: String)? {
        guard !sourcePaths.isEmpty,
              let destination = normalizedAbsolutePath(destinationDirectory),
              isWritableDirectory(destination) else {
            return nil
        }

        let sources = sourcePaths.compactMap(normalizedMutableItem)
        guard sources.count == sourcePaths.count,
              Set(sources).count == sources.count else {
            return nil
        }
        for source in sources {
            guard parent(of: source) != destination,
                  !isSameOrDescendant(destination, of: source) else {
                return nil
            }
        }
        return (sources, destination)
    }

    static func normalizedPreview(path: String, filename: String) -> (path: String, filename: String)? {
        guard let path = normalizedAbsolutePath(path),
              path != CasaFile.serverRootPath,
              isSafeFilename(filename) else {
            return nil
        }
        return (path, filename)
    }

    static func parent(of path: String) -> String? {
        guard let normalized = normalizedAbsolutePath(path),
              normalized != CasaFile.serverRootPath else {
            return nil
        }
        let parent = (normalized as NSString).deletingLastPathComponent
        return parent.isEmpty ? CasaFile.serverRootPath : parent
    }

    private static func hasTraversalComponent(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == "." || $0 == ".." }
    }

    private static func isSameOrDescendant(_ path: String, of directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && filename.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

enum PowerState: String, Sendable {
    case restart
    case shutdown = "off"
}

enum CasaOSError: LocalizedError, Sendable {
    case invalidEndpoint
    case invalidResponse
    case unauthorized
    case noSession
    case server(status: Int, message: String)
    case contract(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The server address is invalid."
        case .invalidResponse:
            "CasaOS returned an invalid response."
        case .unauthorized:
            "The CasaOS session is no longer valid. Please sign in again."
        case .noSession:
            "Sign in to CasaOS first."
        case let .server(status, message):
            message.isEmpty ? "CasaOS request failed (HTTP \(status))." : message
        case let .contract(message):
            message
        }
    }
}

actor MockCasaOSClient: CasaOSClient {
    private var summary: ServerSummary
    private var storageDrives: [StorageDrive]
    private var systemDrives: [StorageDrive]
    private var driveHealthByPath: [String: PhysicalDriveHealth]
    private var apps: [CasaApp]
    private var files: [String: [CasaFile]]
    private var signedIn = true

    init(
        summary: ServerSummary = ServerSummary(
            name: "CasaOS",
            version: "Mock mode",
            status: .online,
            model: "Personal cloud",
            architecture: "arm64",
            cpuPercent: 18,
            memoryPercent: 42,
            memoryUsed: 3_600_000_000,
            memoryTotal: 8_000_000_000,
            diskPercent: 37,
            diskUsed: 740_000_000_000,
            diskFree: 1_260_000_000_000,
            diskTotal: 2_000_000_000_000,
            temperature: 49
        ),
        apps: [CasaApp] = [
            CasaApp(
                id: "jellyfin",
                name: "Jellyfin",
                status: "running",
                iconURL: nil,
                scheme: "http",
                hostname: nil,
                port: "8096",
                path: "/",
                appType: "v2app"
            ),
            CasaApp(
                id: "syncthing",
                name: "Syncthing",
                status: "stopped",
                iconURL: nil,
                scheme: "http",
                hostname: nil,
                port: "8384",
                path: "/",
                appType: "v2app"
            ),
        ],
        storageDrives: [StorageDrive] = [
            StorageDrive(
                id: "/dev/sda",
                name: "zimaraid",
                devicePaths: ["/dev/sda", "/dev/sdb"],
                mountPoints: ["/mnt/zimaraid"],
                totalBytes: 4_000_000_000_000,
                usedBytes: 2_500_000_000_000,
                freeBytes: 1_500_000_000_000
            ),
            StorageDrive(
                id: "/dev/sdc",
                name: "SanDisk",
                devicePaths: ["/dev/sdc"],
                mountPoints: ["/mnt/SanDisk"],
                totalBytes: 2_000_000_000_000,
                usedBytes: 1_250_000_000_000,
                freeBytes: 750_000_000_000
            ),
        ],
        systemDrives: [StorageDrive] = [
            StorageDrive(
                id: "/dev/nvme0n1",
                name: "System",
                devicePaths: ["/dev/nvme0n1"],
                mountPoints: ["/"],
                totalBytes: 1_000_000_000_000,
                usedBytes: 370_000_000_000,
                freeBytes: 630_000_000_000
            ),
        ],
        driveHealth: [PhysicalDriveHealth] = [
            PhysicalDriveHealth(
                devicePath: "/dev/nvme0n1",
                name: "System Drive",
                model: "Demo NVMe SSD",
                serialNumber: "DEMO-NVME",
                diskType: "NVMe",
                capacityBytes: 1_000_000_000_000,
                status: .reportedHealthy,
                temperatureCelsius: 38
            ),
            PhysicalDriveHealth(
                devicePath: "/dev/sda",
                name: "Drive 1",
                model: "Seagate IronWolf",
                serialNumber: "DEMO-SDA",
                diskType: "HDD",
                capacityBytes: 4_000_000_000_000,
                status: .reportedHealthy,
                temperatureCelsius: 33
            ),
            PhysicalDriveHealth(
                devicePath: "/dev/sdb",
                name: "Drive 2",
                model: "Seagate IronWolf",
                serialNumber: "DEMO-SDB",
                diskType: "HDD",
                capacityBytes: 4_000_000_000_000,
                status: .reportedHealthy,
                temperatureCelsius: 35
            ),
            PhysicalDriveHealth(
                devicePath: "/dev/sdc",
                name: "SanDisk",
                model: "SanDisk Extreme",
                serialNumber: "DEMO-SDC",
                diskType: "SSD",
                capacityBytes: 2_000_000_000_000,
                status: .reportedHealthy,
                temperatureCelsius: 30
            ),
        ],
        files: [String: [CasaFile]] = [
            CasaFile.serverRootPath: [
                CasaFile(name: "DATA", path: "/DATA", isDirectory: true, size: 0, modified: nil),
                CasaFile(name: "etc", path: "/etc", isDirectory: true, size: 0, modified: nil),
            ],
            CasaFile.rootPath: [
                CasaFile(name: "Documents", path: "/DATA/Documents", isDirectory: true, size: 0, modified: nil),
                CasaFile(name: "welcome.txt", path: "/DATA/welcome.txt", isDirectory: false, size: 1_024, modified: .now),
            ],
            "/etc": [
                CasaFile(name: "hosts", path: "/etc/hosts", isDirectory: false, size: 256, modified: .now),
            ],
        ]
    ) {
        self.summary = summary
        self.storageDrives = storageDrives
        self.systemDrives = systemDrives
        self.driveHealthByPath = Dictionary(
            uniqueKeysWithValues: driveHealth.map { ($0.devicePath, $0) }
        )
        self.apps = apps
        self.files = files
    }

    func restoreSession() async throws -> Bool { signedIn }

    func validateSession() async throws {
        try requireSession()
    }

    func login(username: String, password: String) async throws {
        guard !username.isEmpty, !password.isEmpty else { throw CasaOSError.unauthorized }
        signedIn = true
    }

    func logout() async {
        signedIn = false
    }

    func fetchServerSummary() async throws -> ServerSummary {
        try requireSession()
        return summary
    }

    func fetchStorageDrives() async throws -> [StorageDrive] {
        try requireSession()
        return storageDrives
    }

    func fetchSystemDrives() async throws -> [StorageDrive] {
        try requireSession()
        return systemDrives
    }

    func fetchDriveHealth(devicePath: String) async throws -> PhysicalDriveHealth {
        try requireSession()
        let requestedPath = devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedPath.isEmpty else {
            throw CasaOSError.contract("A physical drive path is required.")
        }
        if let health = driveHealthByPath[requestedPath] {
            return health
        }
        return PhysicalDriveHealth(
            devicePath: requestedPath,
            name: (requestedPath as NSString).lastPathComponent,
            model: nil,
            serialNumber: nil,
            diskType: nil,
            capacityBytes: nil,
            status: .unavailable,
            temperatureCelsius: nil
        )
    }

    func fetchApps() async throws -> [CasaApp] {
        try requireSession()
        return apps
    }

    func setAppStatus(_ status: AppAction, appID: String) async throws {
        try requireSession()
        guard let index = apps.firstIndex(where: { $0.id == appID }) else {
            throw CasaOSError.contract("App not found.")
        }
        let app = apps[index]
        apps[index] = CasaApp(
            id: app.id,
            name: app.name,
            status: status == .stop ? "stopped" : "running",
            iconURL: app.iconURL,
            scheme: app.scheme,
            hostname: app.hostname,
            port: app.port,
            path: app.path,
            appType: app.appType
        )
    }

    func listFiles(at path: String) async throws -> [CasaFile] {
        try requireSession()
        return files[path] ?? []
    }

    func createFolder(at path: String) async throws {
        try requireSession()
        guard let path = CasaFilePathPolicy.normalizedMutableItem(path),
              let parent = CasaFilePathPolicy.parent(of: path) else {
            throw CasaOSError.contract("Casa Native only creates folders at safe absolute paths.")
        }
        guard !containsMockItem(at: path) else {
            throw CasaOSError.contract("The requested file operation could not be completed.")
        }
        let entry = CasaFile(
            name: (path as NSString).lastPathComponent,
            path: path,
            isDirectory: true,
            size: 0,
            modified: .now
        )
        files[parent, default: []].append(entry)
        files[path] = []
    }

    func uploadFile(data: Data, named name: String, to directory: String) async throws {
        try requireSession()
        guard let directory = CasaFilePathPolicy.normalizedUploadDirectory(
            directory,
            filename: name
        ) else {
            throw CasaOSError.contract("Casa Native only uploads files to safe absolute paths.")
        }
        let path = (directory as NSString).appendingPathComponent(name)
        guard !containsMockItem(at: path) else {
            throw CasaOSError.contract("The requested file operation could not be completed.")
        }
        files[directory, default: []].append(
            CasaFile(
                name: name,
                path: path,
                isDirectory: false,
                size: Int64(data.count),
                modified: .now
            )
        )
    }

    func downloadFile(at path: String) async throws -> Data {
        try requireSession()
        return Data("Casa Native mock download for \(path)\n".utf8)
    }

    func renameItem(
        at sourcePath: String,
        to destinationPath: String,
        isDirectory: Bool
    ) async throws {
        try requireSession()
        guard let paths = CasaFilePathPolicy.normalizedRename(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            isDirectory: isDirectory
        ) else {
            throw CasaOSError.contract("Casa Native only renames items using safe absolute paths.")
        }
        guard containsMockItem(at: paths.source),
              !containsMockItem(at: paths.destination) else {
            throw CasaOSError.contract("The requested file operation could not be completed.")
        }
        remapMockSubtree(from: paths.source, to: paths.destination)
    }

    func transferItems(
        at sourcePaths: [String],
        to destinationDirectory: String,
        operation: CasaFileOperation,
        collisionPolicy: CasaFileCollisionPolicy
    ) async throws {
        try requireSession()
        guard let transfer = CasaFilePathPolicy.normalizedTransfer(
            sourcePaths: sourcePaths,
            destinationDirectory: destinationDirectory
        ) else {
            throw CasaOSError.contract("Casa Native only transfers items using safe absolute paths.")
        }

        for source in transfer.sources {
            guard containsMockItem(at: source) else {
                throw CasaOSError.contract("The requested file operation could not be completed.")
            }
            let destination = (transfer.destination as NSString)
                .appendingPathComponent((source as NSString).lastPathComponent)
            if containsMockItem(at: destination) {
                if collisionPolicy == .skip { continue }
                removeMockSubtree(at: destination)
            }
            if operation == .move {
                remapMockSubtree(from: source, to: destination)
            } else {
                copyMockSubtree(from: source, to: destination)
            }
        }
    }

    func prepareFileForPreview(at path: String, named filename: String) async throws -> URL {
        try requireSession()
        guard let preview = CasaFilePathPolicy.normalizedPreview(path: path, filename: filename) else {
            throw CasaOSError.contract("Casa Native only previews safe absolute file paths.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CasaNativePreview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(preview.filename, isDirectory: false)
            try Data("Casa Native mock preview for \(preview.path)\n".utf8).write(to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func prepareFileForThumbnail(at path: String, named filename: String) async throws -> URL {
        try requireSession()
        guard let thumbnail = CasaFilePathPolicy.normalizedPreview(path: path, filename: filename) else {
            throw CasaOSError.contract(
                "Casa Native only prepares thumbnails for safe absolute file paths."
            )
        }
        try Task.checkCancellation()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CasaNativeThumbnail-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(thumbnail.filename, isDirectory: false)
            try Data("Casa Native mock thumbnail for \(thumbnail.path)\n".utf8).write(to: url)
            try Task.checkCancellation()
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func deleteFiles(at paths: [String]) async throws {
        try requireSession()
        let normalizedPaths = paths.compactMap(CasaFilePathPolicy.normalizedMutableItem)
        guard !paths.isEmpty, normalizedPaths.count == paths.count else {
            throw CasaOSError.contract("Casa Native only deletes items using safe absolute paths.")
        }
        for path in normalizedPaths {
            removeMockSubtree(at: path)
        }
    }

    func setPowerState(_ state: PowerState) async throws {
        try requireSession()
        summary = ServerSummary(name: summary.name, version: summary.version, status: .offline)
    }

    private func requireSession() throws {
        guard signedIn else { throw CasaOSError.noSession }
    }

    private func containsMockItem(at path: String) -> Bool {
        files[path] != nil || files.values.contains { entries in
            entries.contains { $0.path == path }
        }
    }

    private func removeMockSubtree(at path: String) {
        let prefix = path + "/"
        files = files.reduce(into: [:]) { result, pair in
            guard pair.key != path, !pair.key.hasPrefix(prefix) else { return }
            result[pair.key] = pair.value.filter {
                $0.path != path && !$0.path.hasPrefix(prefix)
            }
        }
    }

    private func remapMockSubtree(from source: String, to destination: String) {
        rebuildMockFiles { path in
            remappedMockPath(path, from: source, to: destination)
        }
    }

    private func copyMockSubtree(from source: String, to destination: String) {
        let sourcePrefix = source + "/"
        let copiedDirectoryKeys = files.keys.filter {
            $0 == source || $0.hasPrefix(sourcePrefix)
        }
        let copiedEntries = files.values.flatMap { $0 }.filter {
            $0.path == source || $0.path.hasPrefix(sourcePrefix)
        }

        for key in copiedDirectoryKeys {
            let copiedKey = remappedMockPath(key, from: source, to: destination)
            if files[copiedKey] == nil {
                files[copiedKey] = []
            }
        }
        for entry in copiedEntries {
            let copiedPath = remappedMockPath(entry.path, from: source, to: destination)
            let copied = CasaFile(
                name: (copiedPath as NSString).lastPathComponent,
                path: copiedPath,
                isDirectory: entry.isDirectory,
                size: entry.size,
                modified: entry.modified
            )
            let parent = CasaFilePathPolicy.parent(of: copiedPath) ?? CasaFile.serverRootPath
            files[parent, default: []].append(copied)
        }
    }

    private func rebuildMockFiles(remapping: (String) -> String) {
        let directoryKeys = Set(files.keys.map(remapping))
        let entries = files.values.flatMap { $0 }.map { entry in
            let path = remapping(entry.path)
            return CasaFile(
                name: (path as NSString).lastPathComponent,
                path: path,
                isDirectory: entry.isDirectory,
                size: entry.size,
                modified: entry.modified
            )
        }
        var rebuilt = Dictionary(uniqueKeysWithValues: directoryKeys.map { ($0, [CasaFile]()) })
        for entry in entries {
            let parent = CasaFilePathPolicy.parent(of: entry.path) ?? CasaFile.serverRootPath
            rebuilt[parent, default: []].append(entry)
        }
        files = rebuilt
    }

    private func remappedMockPath(_ path: String, from source: String, to destination: String) -> String {
        guard path == source || path.hasPrefix(source + "/") else { return path }
        return destination + String(path.dropFirst(source.count))
    }
}
