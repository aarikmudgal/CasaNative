import XCTest
@testable import CasaNative

private final class InMemoryAppPreferences: AppPreferenceStoring {
    private var values: [String: Any]

    init(values: [String: Any] = [:]) {
        self.values = values
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

@MainActor
final class MockCasaOSClientTests: XCTestCase {
    func testAppsLoadCancellationNeverBecomesUserFacingError() {
        XCTAssertNil(AppsLoadErrorPolicy.userFacingMessage(
            for: CancellationError(),
            taskIsCancelled: false
        ))
        XCTAssertNil(AppsLoadErrorPolicy.userFacingMessage(
            for: URLError(.cancelled),
            taskIsCancelled: false
        ))
        XCTAssertNil(AppsLoadErrorPolicy.userFacingMessage(
            for: URLError(.timedOut),
            taskIsCancelled: true
        ))
    }

    func testAppsLoadRealFailureRemainsUserFacing() {
        let error = URLError(.timedOut)

        XCTAssertEqual(
            AppsLoadErrorPolicy.userFacingMessage(
                for: error,
                taskIsCancelled: false
            ),
            error.localizedDescription
        )
    }

    func testMockModeLaunchOverrideIsRecognizedWithoutChangingPersistentMode() {
        XCTAssertTrue(AppModel.hasMockModeLaunchOverride(
            arguments: ["Casa Native", "-mockModeEnabled", "YES"]
        ))
        XCTAssertTrue(AppModel.hasMockModeLaunchOverride(
            arguments: ["Casa Native", "-mockModeEnabled=NO"]
        ))
        XCTAssertFalse(AppModel.hasMockModeLaunchOverride(
            arguments: ["Casa Native", "-someOtherFlag", "YES"]
        ))
    }

    func testFreshInstallDefaultsToCasaOSSSHCredentials() {
        let keys = ["sshCredentialMode", "savedEndpoint", "mockModeEnabled"]
        let previous = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        defer {
            for key in keys {
                if let value = previous[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        let model = AppModel(sshCredentialStore: InMemorySSHCredentialStore())

        XCTAssertEqual(model.sshCredentialMode, .casaOS)
    }

    func testSavedSeparateSSHCredentialModeIsPreserved() {
        let key = "sshCredentialMode"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(SSHCredentialMode.separate.rawValue, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let model = AppModel(sshCredentialStore: InMemorySSHCredentialStore())

        XCTAssertEqual(model.sshCredentialMode, .separate)
    }

    func testDefaultCasaOSModeStoresSuccessfulLoginForSSH() async throws {
        let store = InMemorySSHCredentialStore()
        let model = AppModel(
            sshCredentialStore: store,
            preferences: InMemoryAppPreferences()
        )
        model.username = "casa"

        await model.login(password: "same-password")

        XCTAssertEqual(model.connectionState, .connected)
        let saved = try await store.load(
            mode: .casaOS,
            for: model.serverURL
        )
        XCTAssertEqual(
            saved,
            SSHCredentials(username: "casa", password: "same-password")
        )
    }

    func testChangingSSHCredentialModeDoesNotEraseSavedCredentials() async throws {
        let key = "sshCredentialMode"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let store = InMemorySSHCredentialStore()
        let model = AppModel(sshCredentialStore: store)
        let endpoint = model.serverURL
        let casaOS = SSHCredentials(username: "casa", password: "casa-password")
        let separate = SSHCredentials(username: "linux", password: "ssh-password")
        try await store.storeCasaOS(casaOS, for: endpoint)
        try await store.storeSeparate(separate, for: endpoint)

        model.sshCredentialMode = .separate

        let savedCasaOS = try await store.load(mode: .casaOS, for: endpoint)
        let savedSeparate = try await store.load(mode: .separate, for: endpoint)
        XCTAssertEqual(savedCasaOS, casaOS)
        XCTAssertEqual(savedSeparate, separate)
    }

    func testReturnsConfiguredServerSummary() async throws {
        let expected = ServerSummary(
            name: "My CasaOS",
            version: "0.4.15",
            status: .online
        )
        let client = MockCasaOSClient(summary: expected)

        let actual = try await client.fetchServerSummary()

        XCTAssertEqual(actual, expected)
    }

    func testAppLaunchURLUsesActiveServerRouteAndPublishedPort() throws {
        let app = CasaApp(
            id: "jellyfin",
            name: "Jellyfin",
            status: "running (healthy)",
            iconURL: nil,
            scheme: "http",
            hostname: "192.168.1.20",
            port: "8096",
            path: "web/index.html",
            appType: "v2app"
        )
        let server = try XCTUnwrap(URL(string: "http://rpi:80"))

        XCTAssertTrue(app.isRunning)
        XCTAssertEqual(
            app.launchURL(relativeTo: server)?.absoluteString,
            "http://rpi:8096/web/index.html"
        )
    }

    func testAppLaunchURLNeverDowngradesActiveHTTPSRoute() throws {
        let app = CasaApp(
            id: "jellyfin",
            name: "Jellyfin",
            status: "running",
            iconURL: nil,
            scheme: "http",
            hostname: "casaos.local",
            port: "8096",
            path: "/web",
            appType: "v2app"
        )
        let server = try XCTUnwrap(URL(string: "https://rpi.example:8443"))

        XCTAssertEqual(
            app.launchURL(relativeTo: server)?.absoluteString,
            "https://rpi.example:8096/web"
        )
    }

    func testAppearanceModesMapToExpectedColorSchemes() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
        XCTAssertEqual(AppearanceMode.allCases.map(\.title), [
            "System Default",
            "Light",
            "Dark",
        ])
    }

    func testStorageDriveClassifiesMultiplePhysicalMembersAsRAIDCluster() async throws {
        let client = MockCasaOSClient()

        let drives = try await client.fetchStorageDrives()
        let cluster = try XCTUnwrap(drives.first { $0.name == "zimaraid" })
        let standalone = try XCTUnwrap(drives.first { $0.name == "SanDisk" })

        XCTAssertTrue(cluster.isRAIDCluster)
        XCTAssertEqual(cluster.devicePaths, ["/dev/sda", "/dev/sdb"])
        XCTAssertFalse(standalone.isRAIDCluster)
        XCTAssertEqual(standalone.devicePaths, ["/dev/sdc"])
    }

    func testMockSystemDriveAndHealthUseExactPhysicalPath() async throws {
        let client = MockCasaOSClient()

        let drives = try await client.fetchSystemDrives()
        let system = try XCTUnwrap(drives.first)

        XCTAssertEqual(drives.count, 1)
        XCTAssertEqual(system.devicePaths, ["/dev/nvme0n1"])
        XCTAssertEqual(system.mountPoints, ["/"])
        XCTAssertFalse(system.isRAIDCluster)

        let health = try await client.fetchDriveHealth(devicePath: "/dev/nvme0n1")
        XCTAssertEqual(health.devicePath, "/dev/nvme0n1")
        XCTAssertEqual(health.status, .reportedHealthy)
        XCTAssertEqual(health.temperatureCelsius, 38)
    }

    func testMockDriveHealthIsFetchedForOneExactMember() async throws {
        let client = MockCasaOSClient()

        let health = try await client.fetchDriveHealth(devicePath: "/dev/sdb")

        XCTAssertEqual(health.devicePath, "/dev/sdb")
        XCTAssertEqual(health.status, .reportedHealthy)
        XCTAssertEqual(health.temperatureCelsius, 35)
    }

    func testMockOmittedDriveHealthReturnsHTTPStyleUnavailableFallback() async throws {
        let client = MockCasaOSClient(driveHealth: [])

        let health = try await client.fetchDriveHealth(devicePath: "  /dev/usb-missing  ")

        XCTAssertEqual(health.devicePath, "/dev/usb-missing")
        XCTAssertEqual(health.name, "usb-missing")
        XCTAssertEqual(health.status, .unavailable)
        XCTAssertNil(health.model)
        XCTAssertNil(health.serialNumber)
        XCTAssertNil(health.diskType)
        XCTAssertNil(health.capacityBytes)
        XCTAssertNil(health.temperatureCelsius)
    }

    func testMockRenameMovesDirectoryAndDescendants() async throws {
        let client = makeFileClient()

        try await client.renameItem(
            at: "/DATA/Documents/Folder",
            to: "/DATA/Documents/Renamed",
            isDirectory: true
        )

        let documents = try await client.listFiles(at: "/DATA/Documents")
        XCTAssertEqual(documents.map(\.path), ["/DATA/Documents/Renamed"])
        let renamed = try await client.listFiles(at: "/DATA/Documents/Renamed")
        XCTAssertEqual(renamed.map(\.path), ["/DATA/Documents/Renamed/note.txt"])
    }

    func testMockCopyRecursivelyKeepsSourceAndMoveRemovesIt() async throws {
        let client = makeFileClient()

        try await client.transferItems(
            at: ["/DATA/Documents/Folder"],
            to: "/DATA/Archive",
            operation: .copy,
            collisionPolicy: .skip
        )

        let sourceContents = try await client.listFiles(at: "/DATA/Documents/Folder")
        let copiedContents = try await client.listFiles(at: "/DATA/Archive/Folder")
        XCTAssertEqual(sourceContents.map(\.name), ["note.txt"])
        XCTAssertEqual(copiedContents.map(\.name), ["note.txt"])

        try await client.transferItems(
            at: ["/DATA/Documents/Folder"],
            to: "/DATA/Moved",
            operation: .move,
            collisionPolicy: .skip
        )

        let removedContents = try await client.listFiles(at: "/DATA/Documents/Folder")
        let movedContents = try await client.listFiles(at: "/DATA/Moved/Folder")
        XCTAssertTrue(removedContents.isEmpty)
        XCTAssertEqual(movedContents.map(\.name), ["note.txt"])
    }

    func testMockPreviewReturnsNamedTemporaryPayload() async throws {
        let client = MockCasaOSClient()

        let url = try await client.prepareFileForPreview(
            at: "/etc/hosts",
            named: "hosts.txt"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "hosts.txt")
        XCTAssertTrue(
            String(decoding: try Data(contentsOf: url), as: UTF8.self)
                .contains("/etc/hosts")
        )
    }

    func testMockPreviewPlacementFailureRemovesTemporaryDirectory() async throws {
        let before = try temporaryPreviewItemNames()
        let client = MockCasaOSClient()
        let overlongLegalFilename = String(repeating: "a", count: 300) + ".txt"

        do {
            _ = try await client.prepareFileForPreview(
                at: "/etc/hosts",
                named: overlongLegalFilename
            )
            XCTFail("Expected mock preview placement to fail")
        } catch {
            XCTAssertFalse(error is CasaOSError)
        }

        XCTAssertEqual(try temporaryPreviewItemNames(), before)
    }

    func testMockThumbnailReturnsNamedTemporaryPayload() async throws {
        let client = MockCasaOSClient()

        let url = try await client.prepareFileForThumbnail(
            at: "/DATA/Photos/photo.jpg",
            named: "cover.jpg"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "cover.jpg")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix(
            "CasaNativeThumbnail-"
        ))
        XCTAssertTrue(
            String(decoding: try Data(contentsOf: url), as: UTF8.self)
                .contains("/DATA/Photos/photo.jpg")
        )
    }

    func testMockThumbnailPlacementFailureRemovesTemporaryDirectory() async throws {
        let before = try temporaryThumbnailItemNames()
        let client = MockCasaOSClient()
        let overlongLegalFilename = String(repeating: "a", count: 300) + ".png"

        do {
            _ = try await client.prepareFileForThumbnail(
                at: "/DATA/Photos/photo.png",
                named: overlongLegalFilename
            )
            XCTFail("Expected mock thumbnail placement to fail")
        } catch {
            XCTAssertFalse(error is CasaOSError)
        }

        XCTAssertEqual(try temporaryThumbnailItemNames(), before)
    }

    func testMockThumbnailCancellationLeavesNoTemporaryDirectory() async throws {
        let before = try temporaryThumbnailItemNames()
        let client = MockCasaOSClient()

        let task = Task {
            try await client.prepareFileForThumbnail(
                at: "/DATA/Photos/photo.png",
                named: "photo.png"
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected mock thumbnail preparation cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(try temporaryThumbnailItemNames(), before)
    }

    func testMockCreateAppearsInParentAndDeleteRemovesNestedSubtree() async throws {
        let client = makeFileClient()

        try await client.createFolder(at: "/DATA/Documents/New Folder")
        let afterCreate = try await client.listFiles(at: "/DATA/Documents")
        XCTAssertTrue(afterCreate.contains { $0.path == "/DATA/Documents/New Folder" })

        try await client.deleteFiles(at: ["/DATA/Documents/Folder"])
        let afterDelete = try await client.listFiles(at: "/DATA/Documents")
        let deletedContents = try await client.listFiles(at: "/DATA/Documents/Folder")
        XCTAssertFalse(afterDelete.contains { $0.path == "/DATA/Documents/Folder" })
        XCTAssertTrue(deletedContents.isEmpty)
    }

    func testMockCreateAndUploadRejectExistingItemsWithoutLosingOrDuplicatingThem() async throws {
        let client = makeFileClient()

        do {
            try await client.createFolder(at: "/DATA/Documents/Folder")
            XCTFail("Expected existing folder collision")
        } catch {
            XCTAssertEqual(
                (error as? CasaOSError)?.errorDescription,
                "The requested file operation could not be completed."
            )
        }

        let contentsAfterCreate = try await client.listFiles(at: "/DATA/Documents/Folder")
        XCTAssertEqual(contentsAfterCreate.map(\.name), ["note.txt"])
        let folderRows = try await client.listFiles(at: "/DATA/Documents")
            .filter { $0.path == "/DATA/Documents/Folder" }
        XCTAssertEqual(folderRows.count, 1)

        do {
            try await client.uploadFile(
                data: Data("replacement".utf8),
                named: "note.txt",
                to: "/DATA/Documents/Folder"
            )
            XCTFail("Expected existing file collision")
        } catch {
            XCTAssertEqual(
                (error as? CasaOSError)?.errorDescription,
                "The requested file operation could not be completed."
            )
        }

        let contentsAfterUpload = try await client.listFiles(at: "/DATA/Documents/Folder")
        XCTAssertEqual(contentsAfterUpload.map(\.name), ["note.txt"])
        XCTAssertEqual(contentsAfterUpload.first?.size, 4)
    }

    func testMockFileMutationsWorkAcrossServerRoot() async throws {
        let client = MockCasaOSClient()

        try await client.createFolder(at: "/etc/casa-native")
        try await client.uploadFile(data: Data("root".utf8), named: "root.txt", to: "/")
        try await client.renameItem(
            at: "/etc/hosts",
            to: "/etc/hosts.local",
            isDirectory: false
        )
        try await client.transferItems(
            at: ["/etc/hosts.local"],
            to: "/DATA",
            operation: .copy,
            collisionPolicy: .skip
        )
        try await client.deleteFiles(at: ["/etc/casa-native"])

        let root = try await client.listFiles(at: "/")
        let etc = try await client.listFiles(at: "/etc")
        let data = try await client.listFiles(at: "/DATA")
        XCTAssertTrue(root.contains { $0.path == "/root.txt" })
        XCTAssertTrue(etc.contains { $0.path == "/etc/hosts.local" })
        XCTAssertFalse(etc.contains { $0.path == "/etc/casa-native" })
        XCTAssertTrue(data.contains { $0.path == "/DATA/hosts.local" })
    }

    private func makeFileClient() -> MockCasaOSClient {
        MockCasaOSClient(files: [
            "/DATA": [
                CasaFile(
                    name: "Documents",
                    path: "/DATA/Documents",
                    isDirectory: true,
                    size: 0,
                    modified: nil
                ),
                CasaFile(
                    name: "Archive",
                    path: "/DATA/Archive",
                    isDirectory: true,
                    size: 0,
                    modified: nil
                ),
                CasaFile(
                    name: "Moved",
                    path: "/DATA/Moved",
                    isDirectory: true,
                    size: 0,
                    modified: nil
                ),
            ],
            "/DATA/Documents": [
                CasaFile(
                    name: "Folder",
                    path: "/DATA/Documents/Folder",
                    isDirectory: true,
                    size: 0,
                    modified: nil
                ),
            ],
            "/DATA/Documents/Folder": [
                CasaFile(
                    name: "note.txt",
                    path: "/DATA/Documents/Folder/note.txt",
                    isDirectory: false,
                    size: 4,
                    modified: nil
                ),
            ],
            "/DATA/Archive": [],
            "/DATA/Moved": [],
        ])
    }

    private func temporaryPreviewItemNames() throws -> Set<String> {
        let urls = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        return Set(
            urls.map(\.lastPathComponent).filter { $0.hasPrefix("CasaNativePreview-") }
        )
    }

    private func temporaryThumbnailItemNames() throws -> Set<String> {
        let urls = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        return Set(
            urls.map(\.lastPathComponent).filter { $0.hasPrefix("CasaNativeThumbnail-") }
        )
    }
}
