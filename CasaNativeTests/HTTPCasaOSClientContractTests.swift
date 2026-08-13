import Foundation
import XCTest
@testable import CasaNative

@MainActor
final class HTTPCasaOSClientContractTests: XCTestCase {
    private let baseURL = URL(string: "http://casaos.test:8080")!

    override func tearDown() {
        CasaOSURLProtocol.reset()
        super.tearDown()
    }

    func testProbeUsesPublicUserStatusEndpointWithoutAuthorization() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.userStatus)
        }
        let client = try makeClient()

        try await client.verifyServer()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/users/status")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testLoginSendsCredentialsAndStoresContractTokens() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.login)
        }
        let store = InMemorySessionTokenStore()
        let client = try makeClient(tokenStore: store)

        try await client.login(username: "casa", password: "secret")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/users/login")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(object, ["username": "casa", "password": "secret"])

        let stored = try await store.load(for: baseURL)
        XCTAssertEqual(stored?.accessToken, "raw.access.token")
        XCTAssertEqual(stored?.refreshToken, "raw.refresh.token")
        XCTAssertEqual(stored?.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testAuthenticatedRequestUsesRawAuthorizationToken() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.apps)
        }
        let client = try makeAuthenticatedClient(accessToken: "header.payload.signature")

        let apps = try await client.fetchApps()

        XCTAssertEqual(apps.map(\.id), ["syncthing"])
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/v2/app_management/compose")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "header.payload.signature"
        )
        XCTAssertFalse(
            request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") ?? true
        )
    }

    func testAppsUseComposeIDWhenLocalizedTitleIsBlank() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(for: request, body: CasaOSContractFixtures.blankTitleApp)
        }
        let client = try makeAuthenticatedClient()

        let apps = try await client.fetchApps()

        XCTAssertEqual(apps.map(\.name), ["pihole"])
    }

    func testUnauthorizedRequestRefreshesStoredTokensAndRetries() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            switch request.url?.path {
            case "/v1/users/refresh":
                return Self.response(for: request, body: CasaOSContractFixtures.refresh)
            case "/v2/app_management/compose":
                if request.value(forHTTPHeaderField: "Authorization") == "expired.access" {
                    return Self.response(
                        for: request,
                        statusCode: 401,
                        body: Data(#"{"message":"expired"}"#.utf8)
                    )
                }
                return Self.response(for: request, body: CasaOSContractFixtures.apps)
            default:
                throw CasaOSURLProtocolStubError.unexpectedPath(request.url?.path)
            }
        }
        let origin = try EndpointOrigin(endpoint: baseURL)
        let store = InMemorySessionTokenStore(tokensByOrigin: [
            origin: SessionTokens(
                accessToken: "expired.access",
                refreshToken: "old.refresh"
            ),
        ])
        let client = try makeClient(tokenStore: store)

        let apps = try await client.fetchApps()

        XCTAssertEqual(apps.map(\.id), ["syncthing"])
        XCTAssertEqual(
            recorder.requests.map { $0.url?.path },
            [
                "/v2/app_management/compose",
                "/v1/users/refresh",
                "/v2/app_management/compose",
            ]
        )
        let refreshRequest = try XCTUnwrap(
            recorder.requests.first { $0.url?.path == "/v1/users/refresh" }
        )
        XCTAssertNil(refreshRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                [String: String].self,
                from: XCTUnwrap(refreshRequest.httpBody)
            ),
            ["refresh_token": "old.refresh"]
        )
        XCTAssertEqual(
            recorder.requests.last?.value(forHTTPHeaderField: "Authorization"),
            "refreshed.access"
        )
        let stored = try await store.load(for: origin)
        XCTAssertEqual(stored?.accessToken, "refreshed.access")
        XCTAssertEqual(stored?.refreshToken, "refreshed.refresh")
    }

    func testValidateRestoredSessionUsesAuthenticatedReadOnlyRoute() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.version)
        }
        let client = try makeAuthenticatedClient(accessToken: "saved.access")

        let restored = try await client.restoreSession()
        XCTAssertTrue(restored)
        try await client.validateSession()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/sys/version/current")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "saved.access"
        )
    }

    func testValidateSessionClearsUnrefreshableUnauthorizedToken() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(
                for: request,
                statusCode: 401,
                body: Data(#"{"message":"expired"}"#.utf8)
            )
        }
        let origin = try EndpointOrigin(endpoint: baseURL)
        let store = InMemorySessionTokenStore(tokensByOrigin: [
            origin: SessionTokens(accessToken: "expired.access"),
        ])
        let client = try makeClient(tokenStore: store)

        let restored = try await client.restoreSession()
        XCTAssertTrue(restored)
        do {
            try await client.validateSession()
            XCTFail("Expected unauthorized session validation.")
        } catch CasaOSError.unauthorized {
            // Expected: stale session is removed and login becomes reachable.
        } catch {
            XCTFail("Expected CasaOSError.unauthorized, got \(error)")
        }
        let stored = try await store.load(for: origin)
        XCTAssertNil(stored)
        let restoredAfterFailure = try await client.restoreSession()
        XCTAssertFalse(restoredAfterFailure)
    }

    func testServerSummaryCombinesVersionHardwareAndUtilizationContracts() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            let body: Data
            switch request.url?.path {
            case "/v1/sys/version/current":
                body = CasaOSContractFixtures.version
            case "/v1/sys/hardware":
                body = CasaOSContractFixtures.hardware
            case "/v1/sys/utilization":
                body = CasaOSContractFixtures.utilization
            default:
                throw CasaOSURLProtocolStubError.unexpectedPath(request.url?.path)
            }
            return Self.response(for: request, body: body)
        }
        let client = try makeAuthenticatedClient(accessToken: "dashboard.token")

        let summary = try await client.fetchServerSummary()

        XCTAssertEqual(summary.version, "0.4.15")
        XCTAssertEqual(summary.model, "ZimaBoard 832")
        XCTAssertEqual(summary.architecture, "amd64")
        XCTAssertEqual(summary.cpuPercent, 12.5)
        XCTAssertEqual(summary.memoryPercent, 37.5)
        XCTAssertEqual(summary.memoryUsed, 3_000_000_000)
        XCTAssertEqual(summary.memoryTotal, 8_000_000_000)
        XCTAssertEqual(summary.diskPercent, 25)
        XCTAssertEqual(summary.diskUsed, 250_000_000_000)
        XCTAssertEqual(summary.diskFree, 750_000_000_000)
        XCTAssertEqual(summary.diskTotal, 1_000_000_000_000)
        XCTAssertEqual(summary.temperature, 48)

        let requests = recorder.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            Set(requests.compactMap(\.url?.path)),
            Set([
                "/v1/sys/version/current",
                "/v1/sys/hardware",
                "/v1/sys/utilization",
            ])
        )
        XCTAssertNil(
            requests.first { $0.url?.path == "/v1/sys/version/current" }?
                .value(forHTTPHeaderField: "Authorization")
        )
        for path in ["/v1/sys/hardware", "/v1/sys/utilization"] {
            XCTAssertEqual(
                requests.first { $0.url?.path == path }?
                    .value(forHTTPHeaderField: "Authorization"),
                "dashboard.token"
            )
        }
    }

    func testServerSummaryCachesStaticMetadataAcrossPollingRefreshes() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            let body: Data
            switch request.url?.path {
            case "/v1/sys/version/current":
                body = CasaOSContractFixtures.version
            case "/v1/sys/hardware":
                body = CasaOSContractFixtures.hardware
            case "/v1/sys/utilization":
                body = CasaOSContractFixtures.utilization
            default:
                throw CasaOSURLProtocolStubError.unexpectedPath(request.url?.path)
            }
            return Self.response(for: request, body: body)
        }
        let client = try makeAuthenticatedClient()

        _ = try await client.fetchServerSummary()
        _ = try await client.fetchServerSummary()

        let paths = recorder.requests.compactMap(\.url?.path)
        XCTAssertEqual(paths.filter { $0 == "/v1/sys/version/current" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/v1/sys/hardware" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "/v1/sys/utilization" }.count, 2)
        XCTAssertEqual(paths.count, 4)
    }

    func testStorageListGroupsDuplicateFilesystemMembersButKeepsDistinctMounts() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.storage)
        }
        let client = try makeAuthenticatedClient(accessToken: "storage.token")

        let drives = try await client.fetchStorageDrives()

        XCTAssertEqual(drives.count, 2)

        let raid = try XCTUnwrap(
            drives.first { $0.mountPoints == ["/mnt/zimaraid"] }
        )
        XCTAssertEqual(raid.name, "zimaraid")
        XCTAssertEqual(raid.devicePaths, ["/dev/sda", "/dev/sdb"])
        XCTAssertEqual(raid.totalBytes, 4_000_000_000_000)
        XCTAssertEqual(raid.usedBytes, 2_500_000_000_000)
        XCTAssertEqual(raid.freeBytes, 1_500_000_000_000)
        XCTAssertEqual(
            try XCTUnwrap(raid.usedPercent),
            62.5,
            accuracy: 0.0001
        )

        let archive = try XCTUnwrap(
            drives.first { $0.mountPoints == ["/mnt/archive"] }
        )
        XCTAssertEqual(archive.devicePaths, ["/dev/sdc"])
        XCTAssertEqual(archive.totalBytes, raid.totalBytes)
        XCTAssertEqual(archive.usedBytes, raid.usedBytes)
        XCTAssertEqual(archive.freeBytes, raid.freeBytes)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/storage")
        XCTAssertNil(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "system" }
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "storage.token"
        )
        XCTAssertFalse(drives.flatMap(\.devicePaths).contains("/dev/nvme0n1"))
        XCTAssertFalse(drives.flatMap(\.mountPoints).contains("/"))
    }

    func testSystemStorageUsesAuthenticatedStorageRouteAndReturnsOnlyOSMounts() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.storage)
        }
        let client = try makeAuthenticatedClient(accessToken: "system.token")

        let drives = try await client.fetchSystemDrives()

        XCTAssertEqual(drives.count, 3)
        XCTAssertEqual(
            Set(drives.flatMap(\.devicePaths)),
            Set(["/dev/nvme0n1", "/dev/sdd", "/dev/sde"])
        )
        XCTAssertEqual(
            Set(drives.flatMap(\.mountPoints)),
            Set(["/", "/boot/efi"])
        )
        XCTAssertFalse(drives.flatMap(\.devicePaths).contains("/dev/sda"))
        let system = try XCTUnwrap(
            drives.first { $0.devicePaths == ["/dev/nvme0n1"] }
        )
        XCTAssertEqual(system.mountPoints, ["/"])
        XCTAssertEqual(system.totalBytes, 1_000_000_000_000)
        XCTAssertEqual(system.usedBytes, 250_000_000_000)
        XCTAssertEqual(system.freeBytes, 750_000_000_000)

        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/storage")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "system" }?.value,
            "true"
        )
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "system.token"
        )
    }

    func testSystemStorageGroupsMembersByLogicalChildPath() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(for: request, body: CasaOSContractFixtures.systemStorageCluster)
        }
        let client = try makeAuthenticatedClient()

        let drives = try await client.fetchSystemDrives()

        let cluster = try XCTUnwrap(drives.first)
        XCTAssertEqual(drives.count, 1)
        XCTAssertEqual(cluster.devicePaths, ["/dev/sda", "/dev/sdb"])
        XCTAssertEqual(cluster.mountPoints, ["/"])
        XCTAssertEqual(cluster.totalBytes, 1_000)
        XCTAssertEqual(cluster.usedBytes, 200)
        XCTAssertEqual(cluster.freeBytes, 800)
    }

    func testStorageListGroupsMatchingLogicalChildPathsWhenUsageDiffers() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(for: request, body: CasaOSContractFixtures.storageByLogicalChildPath)
        }
        let client = try makeAuthenticatedClient()

        let drives = try await client.fetchStorageDrives()

        let cluster = try XCTUnwrap(drives.first)
        XCTAssertEqual(drives.count, 1)
        XCTAssertEqual(cluster.devicePaths, ["/dev/sda", "/dev/sdb"])
        XCTAssertEqual(cluster.mountPoints, ["/mnt/pool"])
        XCTAssertEqual(cluster.totalBytes, 1_000)
        XCTAssertEqual(cluster.usedBytes, 200)
        XCTAssertEqual(cluster.freeBytes, 800)
    }

    func testStorageListFallsBackToUUIDAndMountPointWhenLogicalPathsDiffer() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(for: request, body: CasaOSContractFixtures.storageByUUIDMountPoint)
        }
        let client = try makeAuthenticatedClient()

        let drives = try await client.fetchStorageDrives()

        XCTAssertEqual(drives.count, 2)
        XCTAssertEqual(
            drives.first { $0.devicePaths.count == 2 }?.devicePaths,
            ["/dev/sdf", "/dev/sdg"]
        )
        XCTAssertEqual(
            drives.first { $0.devicePaths.count == 1 }?.devicePaths,
            ["/dev/sdh"]
        )
    }

    func testDriveHealthUsesAuthenticatedReadOnlyRouteAndExactDevicePath() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.physicalDisks)
        }
        let client = try makeAuthenticatedClient(accessToken: "smart.token")

        let health = try await client.fetchDriveHealth(devicePath: "/dev/sda")

        XCTAssertEqual(health.devicePath, "/dev/sda")
        XCTAssertEqual(health.name, "Seagate IronWolf")
        XCTAssertEqual(health.model, "Seagate IronWolf")
        XCTAssertEqual(health.serialNumber, "SDA-SERIAL")
        XCTAssertEqual(health.diskType, "HDD")
        XCTAssertEqual(health.capacityBytes, 4_000_000_000_000)
        XCTAssertEqual(health.status, .reportedHealthy)
        XCTAssertEqual(health.temperatureCelsius, 34)

        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/disks")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "smart.token")
    }

    func testDriveHealthNormalizesFailureBooleanAndUnavailableValues() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.physicalDisks)
        }
        let client = try makeAuthenticatedClient()

        let failing = try await client.fetchDriveHealth(devicePath: "/dev/sdb")
        let booleanHealth = try await client.fetchDriveHealth(devicePath: "/dev/sdc")
        let unavailable = try await client.fetchDriveHealth(devicePath: "/dev/sdd")

        XCTAssertEqual(failing.status, .attentionRequired)
        XCTAssertNil(failing.temperatureCelsius)
        XCTAssertEqual(booleanHealth.status, .reportedHealthy)
        XCTAssertEqual(booleanHealth.temperatureCelsius, 29)
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertNil(unavailable.temperatureCelsius)
        XCTAssertEqual(recorder.requests.count, 3)
        XCTAssertTrue(recorder.requests.allSatisfy { $0.url?.path == "/v1/disks" })
    }

    func testDriveHealthUsesUniqueDeviceNameFallbackWhenPathIsUnavailable() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(for: request, body: CasaOSContractFixtures.pathlessPhysicalDisk)
        }
        let client = try makeAuthenticatedClient()

        let health = try await client.fetchDriveHealth(devicePath: "/dev/mmcblk0")

        XCTAssertEqual(health.devicePath, "/dev/mmcblk0")
        XCTAssertEqual(health.name, "mmcblk0")
        XCTAssertEqual(health.status, .reportedHealthy)
        XCTAssertNil(health.model)
        XCTAssertNil(health.serialNumber)
        XCTAssertNil(health.diskType)
        XCTAssertNil(health.temperatureCelsius)
    }

    func testDriveHealthReturnsExplicitUnavailableResultForOmittedOrAmbiguousDrive() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(for: request, body: CasaOSContractFixtures.ambiguousPhysicalDisks)
        }
        let client = try makeAuthenticatedClient()

        let health = try await client.fetchDriveHealth(devicePath: "/dev/sda")

        XCTAssertEqual(health.devicePath, "/dev/sda")
        XCTAssertEqual(health.name, "sda")
        XCTAssertEqual(health.status, .unavailable)
        XCTAssertNil(health.model)
        XCTAssertNil(health.serialNumber)
        XCTAssertNil(health.diskType)
        XCTAssertNil(health.capacityBytes)
        XCTAssertNil(health.temperatureCelsius)
    }

    func testAppStatusUsesJSONPrimitiveStringBody() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.statusAccepted)
        }
        let client = try makeAuthenticatedClient()

        try await client.setAppStatus(.restart, appID: "syncthing")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.url?.path,
            "/v2/app_management/compose/syncthing/status"
        )
        XCTAssertEqual(request.httpBody, Data(#""restart""#.utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testDeleteSendsJSONPathArrayForSafeAbsoluteItems() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.v1Success)
        }
        let client = try makeAuthenticatedClient()
        let paths = ["/DATA/Documents/a.txt", "/etc/hosts"]

        try await client.deleteFiles(at: paths)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/batch")
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: XCTUnwrap(request.httpBody)),
            paths
        )
    }

    func testDeleteRejectsEmptyRootRelativeTraversalAndControlPathsWithoutNetworkRequest() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.v1Success)
        }
        let client = try makeAuthenticatedClient()
        let unsafePaths = [
            [],
            ["/"],
            ["DATA/Documents/not-absolute.txt"],
            ["/DATA/Documents/../Secrets/file.txt"],
            ["/DATA/Documents/../../../etc/passwd"],
            ["/etc/pass\u{0000}wd"],
        ]

        for paths in unsafePaths {
            do {
                try await client.deleteFiles(at: paths)
                XCTFail("Expected delete rejection for \(paths)")
            } catch {
                XCTAssertEqual(
                    (error as? CasaOSError)?.errorDescription,
                    "Casa Native only deletes items using safe absolute paths."
                )
            }
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testCreateFolderRejectsRootRelativeTraversalAndControlPathsWithoutNetworkRequest() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.v1Success)
        }
        let client = try makeAuthenticatedClient()
        let unsafePaths = [
            "/",
            "DATA/New Folder",
            "/DATA/Documents/../New Folder",
            "/etc/New\u{0000}Folder",
        ]

        for path in unsafePaths {
            do {
                try await client.createFolder(at: path)
                XCTFail("Expected create-folder rejection for \(path)")
            } catch {
                XCTAssertEqual(
                    (error as? CasaOSError)?.errorDescription,
                    "Casa Native only creates folders at safe absolute paths."
                )
            }
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testUploadRejectsRelativeTraversalControlAndUnsafeFilenameWithoutNetworkRequest() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: Data())
        }
        let client = try makeAuthenticatedClient()
        let unsafeTargets = [
            (directory: "DATA/Documents", filename: "note.txt"),
            (directory: "/DATA/Documents/../Secrets", filename: "note.txt"),
            (directory: "/etc\u{0000}", filename: "note.txt"),
            (directory: "/DATA", filename: ".."),
            (directory: "/DATA", filename: "../outside.txt"),
            (directory: "/", filename: "bad\u{0000}name"),
            (directory: "/", filename: "bad\r\nX-Injected: true.txt"),
        ]

        for target in unsafeTargets {
            do {
                try await client.uploadFile(
                    data: Data("unsafe".utf8),
                    named: target.filename,
                    to: target.directory
                )
                XCTFail("Expected upload rejection for \(target)")
            } catch {
                XCTAssertEqual(
                    (error as? CasaOSError)?.errorDescription,
                    "Casa Native only uploads files to safe absolute paths."
                )
            }
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testCasaOSAbsolutePathMutationContract() {
        XCTAssertEqual(CasaFile.rootPath, "/DATA")
        XCTAssertEqual(CasaFile.serverRootPath, "/")
        XCTAssertEqual(CasaFilePathPolicy.parent(of: "/DATA/Documents"), "/DATA")
        XCTAssertEqual(CasaFilePathPolicy.parent(of: "/DATA"), "/")
        XCTAssertNil(CasaFilePathPolicy.parent(of: "/"))
        XCTAssertTrue(CasaFilePathPolicy.isWritableDirectory("/"))
        XCTAssertTrue(CasaFilePathPolicy.isWritableDirectory("/DATA"))
        XCTAssertTrue(CasaFilePathPolicy.isWritableDirectory("/DATA/Documents"))
        XCTAssertTrue(CasaFilePathPolicy.isWritableDirectory("/DATA2"))
        XCTAssertTrue(CasaFilePathPolicy.isWritableDirectory("/etc"))
        XCTAssertFalse(CasaFilePathPolicy.isWritableDirectory("etc"))
        XCTAssertFalse(CasaFilePathPolicy.isWritableDirectory("/etc/../tmp"))
        XCTAssertNil(CasaFilePathPolicy.normalizedMutableItem("/"))
        XCTAssertEqual(CasaFilePathPolicy.normalizedMutableItem("/etc"), "/etc")
    }

    func testFileListAllowsServerRootPath() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.serverRootFiles)
        }
        let client = try makeAuthenticatedClient()

        let files = try await client.listFiles(at: CasaFile.serverRootPath)

        XCTAssertEqual(files.map(\.path), ["/DATA", "/etc"])
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/folder")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value,
            "/"
        )
    }

    func testFileListUsesPathQueryAndDecodesCasaOSMetadata() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.files)
        }
        let client = try makeAuthenticatedClient()

        let files = try await client.listFiles(at: "/DATA/My Documents")

        XCTAssertEqual(files.map(\.name), ["Photos", "note.txt"])
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[1].size, 42)
        XCTAssertNotNil(files[1].modified)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/folder")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value,
            "/DATA/My Documents"
        )
    }

    func testCreateFolderAndDownloadUseNativeFileEndpoints() async throws {
        let recorder = RequestRecorder()
        let download = Data([0x00, 0x01, 0xFE, 0xFF])
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            if request.url?.path == "/v1/file" {
                return Self.response(for: request, body: download)
            }
            return Self.response(for: request, body: CasaOSContractFixtures.v1Success)
        }
        let client = try makeAuthenticatedClient()

        try await client.createFolder(at: "/etc/New Folder")
        let received = try await client.downloadFile(at: "/DATA/Documents/blob.bin")

        XCTAssertEqual(received, download)
        let create = try XCTUnwrap(
            recorder.requests.first { $0.url?.path == "/v1/folder" }
        )
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(
            try JSONDecoder().decode(
                [String: String].self,
                from: XCTUnwrap(create.httpBody)
            ),
            ["path": "/etc/New Folder"]
        )
        let get = try XCTUnwrap(
            recorder.requests.first { $0.url?.path == "/v1/file" }
        )
        XCTAssertEqual(get.httpMethod, "GET")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(get.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value,
            "/DATA/Documents/blob.bin"
        )
    }

    func testInMemoryDownloadRejectsUnknownLengthBodyBeyondTransportLimit() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: Data(repeating: 0x41, count: 9))
        }
        let client = try makeAuthenticatedClient(fileTransferLimits: .testLimits)

        do {
            _ = try await client.downloadFile(at: "/etc/unknown.bin")
            XCTFail("Expected the streamed download limit to reject the ninth byte")
        } catch {
            XCTAssertEqual(
                (error as? CasaOSError)?.errorDescription,
                "This file exceeds Casa Native's 8 bytes in-memory download limit."
            )
        }

        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testInMemoryDownloadRejectsBodyWhenContentLengthLiesBelowLimit() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(
                for: request,
                body: Data(repeating: 0x42, count: 9),
                headerFields: ["Content-Length": "4"]
            )
        }
        let client = try makeAuthenticatedClient(fileTransferLimits: .testLimits)

        do {
            _ = try await client.downloadFile(at: "/etc/lying.bin")
            XCTFail("Expected the actual streamed byte count to win over Content-Length")
        } catch {
            XCTAssertEqual(
                (error as? CasaOSError)?.errorDescription,
                "This file exceeds Casa Native's 8 bytes in-memory download limit."
            )
        }
    }

    func testInMemoryDownloadRejectsDeclaredOversizeBeforeAcceptingBody() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(
                for: request,
                body: Data([0x43]),
                headerFields: ["Content-Length": "9"]
            )
        }
        let client = try makeAuthenticatedClient(fileTransferLimits: .testLimits)

        do {
            _ = try await client.downloadFile(at: "/etc/declared.bin")
            XCTFail("Expected oversized Content-Length rejection")
        } catch {
            XCTAssertEqual(
                (error as? CasaOSError)?.errorDescription,
                "This file exceeds Casa Native's 8 bytes in-memory download limit."
            )
        }
    }

    func testInMemoryDownloadPreservesLargeChunkedPayloadAtExactLimit() async throws {
        let payload = Data((0..<(256 * 1_024)).map { UInt8(truncatingIfNeeded: $0) })
        CasaOSURLProtocol.install { request in
            Self.response(
                for: request,
                body: payload,
                headerFields: ["X-CasaNative-Test-Chunk-Size": "16384"]
            )
        }
        let limits = CasaFileTransferLimits(
            inMemoryBytes: Int64(payload.count),
            previewBytes: 512 * 1_024,
            uploadBytes: 512 * 1_024
        )
        let client = try makeAuthenticatedClient(fileTransferLimits: limits)

        let received = try await client.downloadFile(at: "/etc/chunked.bin")

        XCTAssertEqual(received, payload)
    }

    func testSingleChunkUploadUsesCasaOSMultipartContract() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: Data())
        }
        let client = try makeAuthenticatedClient()
        let payload = Data("hello from Casa Native".utf8)

        try await client.uploadFile(
            data: payload,
            named: "note.txt",
            to: "/"
        )

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v2/casaos/file/upload")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Type")?
                .hasPrefix("multipart/form-data; boundary=CasaNative-") == true
        )
        let body = try XCTUnwrap(request.httpBody)
        let rendered = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(rendered.contains("name=\"path\"\r\n\r\n/\r\n"))
        XCTAssertTrue(rendered.contains("name=\"relativePath\"\r\n\r\nnote.txt"))
        XCTAssertTrue(rendered.contains("name=\"totalChunks\"\r\n\r\n1"))
        XCTAssertTrue(rendered.contains("filename=\"note.txt\""))
        XCTAssertNotNil(body.range(of: payload))
    }

    func testUploadRejectsDataBeyondHardLimitWithoutNetworkRequest() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: Data())
        }
        let client = try makeAuthenticatedClient(fileTransferLimits: .testLimits)

        do {
            try await client.uploadFile(
                data: Data(repeating: 0x44, count: 9),
                named: "oversized.bin",
                to: "/DATA"
            )
            XCTFail("Expected upload data limit rejection")
        } catch {
            XCTAssertEqual(
                (error as? CasaOSError)?.errorDescription,
                "This file exceeds Casa Native's 8 bytes in-memory transfer limit."
            )
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testUploadFileReaderStopsAtLimitWithoutTrustingMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CasaNativeImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x45, count: 9).write(to: url)

        XCTAssertThrowsError(
            try CasaFileDataReader.readForUpload(from: url, maximumBytes: 8)
        ) { error in
            XCTAssertEqual(
                (error as? CasaOSError)?.errorDescription,
                "This file exceeds Casa Native's 8 bytes in-memory transfer limit."
            )
        }
    }

    func testUploadFileReaderAcceptsExactLimit() throws {
        let payload = Data(repeating: 0x46, count: 8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CasaNativeImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try payload.write(to: url)

        XCTAssertEqual(
            try CasaFileDataReader.readForUpload(from: url, maximumBytes: 8),
            payload
        )
    }

    func testUploadFileReaderHonorsCancellationBeforeReading() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CasaNativeImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x47, count: 8).write(to: url)

        let task = Task.detached {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try CasaFileDataReader.readForUpload(from: url, maximumBytes: 8)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before file reading")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testSecurityScopedUploadReaderCoordinatesSandboxFileAccess() throws {
        let payload = Data("coordinated".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CasaNativeImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try payload.write(to: url)

        XCTAssertEqual(
            try CasaFileUploadBatch.readSecurityScopedFile(
                from: url,
                maximumBytes: Int64(payload.count)
            ),
            payload
        )
    }

    func testUploadBatchProcessesEverySelectionSequentiallyAndReportsEachFailure() async throws {
        let urls = ["first.txt", "too-large.bin", "rejected.txt", "last.txt"]
            .map { URL(fileURLWithPath: "/tmp/\($0)") }
        let recorder = UploadBatchTestRecorder()
        var progressUpdates: [CasaFileUploadProgress] = []

        let summary = try await CasaFileUploadBatch.upload(
            urls: urls,
            to: "/DATA/Uploads",
            maximumBytes: 8,
            reader: { url, maximumBytes in
                guard maximumBytes == 8 else {
                    throw CasaOSError.contract("wrong per-file limit")
                }
                if url.lastPathComponent == "too-large.bin" {
                    throw CasaOSError.contract("too large")
                }
                return Data(url.lastPathComponent.utf8)
            },
            uploader: { data, name, directory in
                XCTAssertEqual(directory, "/DATA/Uploads")
                XCTAssertEqual(data, Data(name.utf8))
                await recorder.begin(name)
                try await Task.sleep(for: .milliseconds(1))
                await recorder.finish()
                if name == "rejected.txt" {
                    throw CasaOSError.contract("server rejected this file")
                }
            },
            onProgress: { progressUpdates.append($0) }
        )

        XCTAssertEqual(summary.totalCount, 4)
        XCTAssertEqual(summary.succeededCount, 2)
        XCTAssertEqual(summary.failures, [
            CasaFileUploadFailure(
                selectionIndex: 1,
                filename: "too-large.bin",
                message: "too large"
            ),
            CasaFileUploadFailure(
                selectionIndex: 2,
                filename: "rejected.txt",
                message: "server rejected this file"
            ),
        ])
        let uploadSnapshot = await recorder.snapshot()
        XCTAssertEqual(uploadSnapshot.names, ["first.txt", "rejected.txt", "last.txt"])
        XCTAssertEqual(uploadSnapshot.maximumActiveCount, 1)
        XCTAssertEqual(uploadSnapshot.activeCount, 0)
        XCTAssertEqual(progressUpdates.first, CasaFileUploadProgress(
            completedCount: 0,
            totalCount: 4,
            currentName: "first.txt",
            failedCount: 0
        ))
        XCTAssertEqual(progressUpdates.last, CasaFileUploadProgress(
            completedCount: 4,
            totalCount: 4,
            currentName: nil,
            failedCount: 2
        ))
    }

    func testUploadBatchPreservesSingleFileUploadBehavior() async throws {
        let url = URL(fileURLWithPath: "/tmp/only.txt")
        let recorder = UploadBatchTestRecorder()

        let summary = try await CasaFileUploadBatch.upload(
            urls: [url],
            to: "/",
            maximumBytes: 128,
            reader: { _, _ in Data("one".utf8) },
            uploader: { _, name, _ in
                await recorder.begin(name)
                await recorder.finish()
            },
            onProgress: { _ in }
        )

        let uploadSnapshot = await recorder.snapshot()
        XCTAssertEqual(uploadSnapshot.names, ["only.txt"])
        XCTAssertEqual(summary.totalCount, 1)
        XCTAssertEqual(summary.succeededCount, 1)
        XCTAssertTrue(summary.failures.isEmpty)
    }

    func testUploadBatchReadsFileDataOffTheMainThread() async throws {
        let recorder = UploadBatchReadThreadRecorder()

        _ = try await CasaFileUploadBatch.upload(
            urls: [URL(fileURLWithPath: "/tmp/background.txt")],
            to: "/DATA",
            maximumBytes: 128,
            reader: { _, _ in
                recorder.record(isMainThread: Thread.isMainThread)
                return Data("background".utf8)
            },
            uploader: { _, _, _ in },
            onProgress: { _ in }
        )

        XCTAssertEqual(recorder.wasMainThread, false)
    }

    func testFileDisplayStyleRestoresKnownValueAndSafelyFallsBackToList() {
        XCTAssertEqual(CasaFileDisplayStyle(storedValue: "grid"), .grid)
        XCTAssertEqual(CasaFileDisplayStyle(storedValue: "future-layout"), .list)
        XCTAssertEqual(CasaFileDisplayStyle.list.toolbarIconName, "list.bullet")
        XCTAssertEqual(CasaFileDisplayStyle.grid.toolbarIconName, "square.grid.2x2")
    }

    func testFilePresentationUsesConsistentIconsAcrossListAndGrid() {
        XCTAssertEqual(CasaFilePresentation.iconName(for: "photo.HEIC"), "photo")
        XCTAssertEqual(CasaFilePresentation.iconName(for: "movie.mkv"), "film")
        XCTAssertEqual(CasaFilePresentation.iconName(for: "song.flac"), "music.note")
        XCTAssertEqual(CasaFilePresentation.iconName(for: "guide.pdf"), "doc.richtext")
        XCTAssertEqual(CasaFilePresentation.iconName(for: "archive.tar"), "doc")
    }

    func testUploadEscapesQuoteAndBackslashInMultipartFilenameHeader() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: Data())
        }
        let client = try makeAuthenticatedClient()
        let filename = "report \"draft\"\\final.txt"

        try await client.uploadFile(
            data: Data("safe payload".utf8),
            named: filename,
            to: "/DATA"
        )

        let request = try XCTUnwrap(recorder.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let rendered = String(decoding: body, as: UTF8.self)
        let disposition = try XCTUnwrap(
            rendered.components(separatedBy: "\r\n").first {
                $0.hasPrefix("Content-Disposition: form-data;")
                    && $0.contains("filename=")
            }
        )
        XCTAssertEqual(
            disposition,
            "Content-Disposition: form-data; name=\"file\"; filename=\"report \\\"draft\\\"\\\\final.txt\""
        )
        XCTAssertTrue(
            rendered.contains("name=\"filename\"\r\n\r\n\(filename)\r\n")
        )
        XCTAssertFalse(rendered.contains("filename=\"\(filename)\""))
    }

    func testRenameUsesCasaOSFileAndFolderNameContracts() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.v1Success)
        }
        let client = try makeAuthenticatedClient()

        try await client.renameItem(
            at: "/etc/hosts",
            to: "/etc/hosts.local",
            isDirectory: false
        )
        try await client.renameItem(
            at: "/DATA/Documents/Old Folder",
            to: "/DATA/Documents/New Folder",
            isDirectory: true
        )

        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["PUT", "PUT"])
        XCTAssertEqual(
            recorder.requests.map { $0.url?.path },
            ["/v1/file/name", "/v1/folder/name"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [String: String].self,
                from: XCTUnwrap(recorder.requests[0].httpBody)
            ),
            ["old_path": "/etc/hosts", "new_path": "/etc/hosts.local"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [String: String].self,
                from: XCTUnwrap(recorder.requests[1].httpBody)
            ),
            [
                "old_path": "/DATA/Documents/Old Folder",
                "new_path": "/DATA/Documents/New Folder",
            ]
        )
    }

    func testTransferUsesCasaOSBatchTaskContract() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.v1Success)
        }
        let client = try makeAuthenticatedClient()

        try await client.transferItems(
            at: ["/etc/hosts", "/DATA/Documents/Photos"],
            to: "/",
            operation: .copy,
            collisionPolicy: .overwrite
        )

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/batch/task")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(body["type"] as? String, "copy")
        XCTAssertEqual(
            body["item"] as? [[String: String]],
            [
                ["from": "/etc/hosts"],
                ["from": "/DATA/Documents/Photos"],
            ]
        )
        XCTAssertEqual(body["to"] as? String, "/")
        XCTAssertEqual(body["style"] as? String, "overwrite")
    }

    func testRenameRejectsUnsafePathsWithoutNetworkRequest() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.v1Success)
        }
        let client = try makeAuthenticatedClient()
        let unsafeRenames = [
            ("/", "/root-new", true),
            ("/etc/hosts", "/DATA/hosts", false),
            ("/DATA/a", "/DATA/a", false),
            ("/DATA/a", "/DATA/Other/a", false),
            ("/DATA/a", "/DATA/a\u{0000}bad", false),
            ("/DATA/folder", "/DATA/folder/child", true),
            ("/DATA/folder", "/DATA/folder/../other", true),
        ]

        for (source, destination, isDirectory) in unsafeRenames {
            do {
                try await client.renameItem(
                    at: source,
                    to: destination,
                    isDirectory: isDirectory
                )
                XCTFail("Expected rename rejection for \(source) to \(destination)")
            } catch {
                XCTAssertEqual(
                    (error as? CasaOSError)?.errorDescription,
                    "Casa Native only renames items using safe absolute paths."
                )
            }
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testTransferRejectsUnsafeAndNoOpPathsWithoutNetworkRequest() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.v1Success)
        }
        let client = try makeAuthenticatedClient()
        let unsafeTransfers: [([String], String)] = [
            ([], "/DATA/Archive"),
            (["/"], "/DATA/Archive"),
            (["DATA/Documents/a.txt"], "/DATA/Archive"),
            (["/DATA/Documents/a.txt"], "etc"),
            (["/DATA/Documents/a.txt"], "/DATA/Documents"),
            (["/DATA/Documents"], "/DATA/Documents/Archive"),
            (["/DATA/Documents/../a.txt"], "/DATA/Archive"),
            (["/DATA/a.txt", "/DATA/a.txt"], "/DATA/Archive"),
            (["/etc/pass\u{0000}wd"], "/DATA/Archive"),
        ]

        for (sources, destination) in unsafeTransfers {
            do {
                try await client.transferItems(
                    at: sources,
                    to: destination,
                    operation: .move,
                    collisionPolicy: .skip
                )
                XCTFail("Expected transfer rejection for \(sources) to \(destination)")
            } catch {
                XCTAssertEqual(
                    (error as? CasaOSError)?.errorDescription,
                    "Casa Native only transfers items using safe absolute paths."
                )
            }
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testPreviewDownloadsAuthenticatedAbsolutePathToNamedTemporaryFile() async throws {
        let recorder = RequestRecorder()
        let payload = Data("127.0.0.1 localhost\n".utf8)
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: payload)
        }
        let client = try makeAuthenticatedClient()

        let url = try await client.prepareFileForPreview(
            at: "/etc/hosts",
            named: "hosts.txt"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "hosts.txt")
        XCTAssertEqual(try Data(contentsOf: url), payload)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/file")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "raw.access.token"
        )
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value,
            "/etc/hosts"
        )
    }

    func testPreviewPlacementFailureRemovesTransportAndPreviewTemporaryItems() async throws {
        let prefixes = ["CasaNativeTransport-", "CasaNativePreview-"]
        let before = try temporaryItemNames(withPrefixes: prefixes)
        CasaOSURLProtocol.install { request in
            Self.response(for: request, body: Data("preview".utf8))
        }
        let client = try makeAuthenticatedClient()
        let overlongLegalFilename = String(repeating: "a", count: 300) + ".txt"

        do {
            _ = try await client.prepareFileForPreview(
                at: "/DATA/preview.txt",
                named: overlongLegalFilename
            )
            XCTFail("Expected final preview placement to fail")
        } catch {
            XCTAssertFalse(error is CasaOSError)
        }

        XCTAssertEqual(try temporaryItemNames(withPrefixes: prefixes), before)
    }

    func testPreviewRejectsUnknownLengthBodyBeyondDiskTransportLimit() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(for: request, body: Data(repeating: 0x47, count: 13))
        }
        let client = try makeAuthenticatedClient(fileTransferLimits: .testLimits)

        do {
            _ = try await client.prepareFileForPreview(
                at: "/etc/unknown-preview.bin",
                named: "unknown-preview.bin"
            )
            XCTFail("Expected the streamed preview limit to reject the thirteenth byte")
        } catch {
            XCTAssertEqual(
                (error as? CasaOSError)?.errorDescription,
                "This file exceeds Casa Native's 12 bytes preview limit."
            )
        }
    }

    func testPreviewRejectsBodyWhenContentLengthLiesBelowLimit() async throws {
        CasaOSURLProtocol.install { request in
            Self.response(
                for: request,
                body: Data(repeating: 0x48, count: 13),
                headerFields: ["Content-Length": "4"]
            )
        }
        let client = try makeAuthenticatedClient(fileTransferLimits: .testLimits)

        do {
            _ = try await client.prepareFileForPreview(
                at: "/etc/lying-preview.bin",
                named: "lying-preview.bin"
            )
            XCTFail("Expected actual preview bytes to win over Content-Length")
        } catch {
            XCTAssertEqual(
                (error as? CasaOSError)?.errorDescription,
                "This file exceeds Casa Native's 12 bytes preview limit."
            )
        }
    }

    func testPreviewRefreshesUnauthorizedSessionAndRetriesDownload() async throws {
        let recorder = RequestRecorder()
        let payload = Data("preview".utf8)
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            if request.url?.path == "/v1/users/refresh" {
                return Self.response(for: request, body: CasaOSContractFixtures.refresh)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "expired.access" {
                return Self.response(
                    for: request,
                    statusCode: 401,
                    body: Data(#"{"message":"expired"}"#.utf8)
                )
            }
            return Self.response(for: request, body: payload)
        }
        let origin = try EndpointOrigin(endpoint: baseURL)
        let store = InMemorySessionTokenStore(tokensByOrigin: [
            origin: SessionTokens(accessToken: "expired.access", refreshToken: "old.refresh"),
        ])
        let client = try makeClient(tokenStore: store)

        let url = try await client.prepareFileForPreview(
            at: "/DATA/note.txt",
            named: "note.txt"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(
            recorder.requests.map { $0.url?.path },
            ["/v1/file", "/v1/users/refresh", "/v1/file"]
        )
        XCTAssertEqual(
            recorder.requests.last?.value(forHTTPHeaderField: "Authorization"),
            "refreshed.access"
        )
    }

    func testPreviewRejectsTraversalControlAndUnsafeFilenameWithoutNetworkRequest() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: Data())
        }
        let client = try makeAuthenticatedClient()
        let unsafePreviews = [
            ("", "note.txt"),
            ("/", "root"),
            ("/DATA/../etc/hosts", "hosts"),
            ("/DATA/a\u{0000}b", "a.txt"),
            ("/DATA/note.txt", "../note.txt"),
            ("/DATA/note.txt", ""),
        ]

        for (path, filename) in unsafePreviews {
            do {
                _ = try await client.prepareFileForPreview(at: path, named: filename)
                XCTFail("Expected preview rejection for \(path), \(filename)")
            } catch {
                XCTAssertEqual(
                    (error as? CasaOSError)?.errorDescription,
                    "Casa Native only previews safe absolute file paths."
                )
            }
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testPowerCommandsUseCasaOSStateEndpoints() async throws {
        let recorder = RequestRecorder()
        CasaOSURLProtocol.install { request in
            recorder.record(request)
            return Self.response(for: request, body: CasaOSContractFixtures.v1Success)
        }
        let client = try makeAuthenticatedClient()

        try await client.setPowerState(.restart)
        try await client.setPowerState(.shutdown)

        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["PUT", "PUT"])
        XCTAssertEqual(
            recorder.requests.map { $0.url?.path },
            ["/v1/sys/state/restart", "/v1/sys/state/off"]
        )
    }

    private func makeAuthenticatedClient(
        accessToken: String = "raw.access.token",
        fileTransferLimits: CasaFileTransferLimits = .production
    ) throws -> HTTPCasaOSClient {
        let origin = try EndpointOrigin(endpoint: baseURL)
        let store = InMemorySessionTokenStore(tokensByOrigin: [
            origin: SessionTokens(accessToken: accessToken),
        ])
        return try makeClient(
            tokenStore: store,
            fileTransferLimits: fileTransferLimits
        )
    }

    private func temporaryItemNames(withPrefixes prefixes: [String]) throws -> Set<String> {
        let urls = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        return Set(urls.map(\.lastPathComponent).filter { name in
            prefixes.contains { name.hasPrefix($0) }
        })
    }

    private func makeClient(
        tokenStore: any SessionTokenStore = InMemorySessionTokenStore(),
        fileTransferLimits: CasaFileTransferLimits = .production
    ) throws -> HTTPCasaOSClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CasaOSURLProtocol.self]
        return HTTPCasaOSClient(
            baseURL: baseURL,
            tokenStore: tokenStore,
            session: URLSession(configuration: configuration),
            fileTransferLimits: fileTransferLimits
        )
    }

    private nonisolated static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        body: Data,
        headerFields: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": "application/json"]
        headers.merge(headerFields) { _, new in new }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, body)
    }
}

private extension CasaFileTransferLimits {
    static let testLimits = CasaFileTransferLimits(
        inMemoryBytes: 8,
        previewBytes: 12,
        uploadBytes: 8
    )
}

private enum CasaOSContractFixtures {
    static let version = data("0.4.15\n")

    static let hardware = data(
        #"{"success":200,"message":"ok","data":{"drive_model":"Zima\u0000Board 832\u0000","arch":"amd\u000064\u0000"}}"#
    )

    static let utilization = data(
        #"{"success":200,"message":"ok","data":{"cpu":{"percent":12.5,"temperature":48},"mem":{"total":8000000000,"used":3000000000,"usedPercent":37.5},"sys_disk":{"size":1000000000000,"used":250000000000,"avail":750000000000,"health":"Healthy"}}}"#
    )

    static let storage = data(
        #"{"success":200,"message":"ok","data":[{"disk_name":"System","size":1000000000000,"path":"/dev/nvme0n1","type":"nvme","children":[{"mount_point":"/","size":"1000000000000","avail":"750000000000","used":"250000000000","type":"ext4","label":"System"}]},{"disk_name":"zimaraid","size":4000000000000,"path":"/dev/sda","type":"sata","children":[{"mount_point":"/mnt/zimaraid","size":"4000000000000","avail":"1500000000000","used":"2500000000000","type":"btrfs","label":"zimaraid"}]},{"disk_name":"zimaraid","size":4000000000000,"path":"/dev/sdb","type":"sata","children":[{"mount_point":"/mnt/zimaraid","size":"4000000000000","avail":"1500000000000","used":"2500000000000","type":"btrfs","label":"zimaraid"}]},{"disk_name":"Archive","size":4000000000000,"path":"/dev/sdc","type":"usb","children":[{"mount_point":"/mnt/archive","size":"4000000000000","avail":"1500000000000","used":"2500000000000","type":"ext4","label":"Archive"}]},{"disk_name":"Unexpected Root","size":500000000000,"path":"/dev/sdd","type":"usb","children":[{"mount_point":"/","size":"500000000000","avail":"300000000000","used":"200000000000","type":"ext4","label":"Root"}]},{"disk_name":"Boot Device","size":1000000000,"path":"/dev/sde","type":"usb","children":[{"mount_point":"/boot/efi","size":"1000000000","avail":"500000000","used":"500000000","type":"vfat","label":"EFI"}]}]}"#
    )

    static let storageByLogicalChildPath = data(
        #"{"success":200,"message":"ok","data":[{"disk_name":"Pool","size":1000,"path":"/dev/sda","children":[{"path":"/dev/mapper/pool","mount_point":"/mnt/pool","size":"1000","avail":"800","used":"200","type":"btrfs","label":"Pool"}]},{"disk_name":"Pool","size":1000,"path":"/dev/sdb","children":[{"path":"/dev/mapper/pool","mount_point":"/mnt/pool","size":"1000","avail":"700","used":"300","type":"btrfs","label":"Pool"}]}]}"#
    )

    static let storageByUUIDMountPoint = data(
        #"{"success":200,"message":"ok","data":[{"disk_name":"Pool","size":1000,"path":"/dev/sdf","children":[{"path":"/dev/sdf1","uuid":"SHARED-UUID","mount_point":"/mnt/pool","size":"1000","avail":"800","used":"200","type":"btrfs","label":"Pool"}]},{"disk_name":"Pool","size":1000,"path":"/dev/sdg","children":[{"path":"/dev/sdg1","uuid":"shared-uuid","mount_point":"/mnt/pool","size":"1000","avail":"700","used":"300","type":"btrfs","label":"Pool"}]},{"disk_name":"Separate","size":1000,"path":"/dev/sdh","children":[{"path":"/dev/sdh1","uuid":"distinct-uuid","mount_point":"/mnt/pool","size":"1000","avail":"800","used":"200","type":"btrfs","label":"Separate"}]}]}"#
    )

    static let systemStorageCluster = data(
        #"{"success":200,"message":"ok","data":[{"disk_name":"System","size":1000,"path":"/dev/sda","children":[{"path":"/dev/mapper/system","mount_point":"/","size":"1000","avail":"800","used":"200","type":"btrfs","label":"System"}]},{"disk_name":"System","size":1000,"path":"/dev/sdb","children":[{"path":"/dev/mapper/system","mount_point":"/","size":"1000","avail":"700","used":"300","type":"btrfs","label":"System"}]}]}"#
    )

    static let physicalDisks = data(
        #"{"success":200,"message":"ok","data":{"disks":[{"name":"sdaa","size":8000000000000,"model":"Different Drive","health":"true","temperature":31,"disk_type":"HDD","serial":"SDAA-SERIAL","path":"/dev/sdaa","children_number":1},{"name":"sda","size":4000000000000,"model":"Seagate IronWolf","health":"true","temperature":34,"disk_type":"HDD","serial":"SDA-SERIAL","path":"/dev/sda","children_number":1},{"name":"sdb","size":4000000000000,"model":"Seagate IronWolf","health":"false","temperature":0,"disk_type":"HDD","serial":"SDB-SERIAL","path":"/dev/sdb","children_number":1},{"name":"sdc","size":2000000000000,"model":"SanDisk Extreme","health":true,"temperature":29,"disk_type":"SSD","serial":"SDC-SERIAL","path":"/dev/sdc","children_number":1},{"name":"sdd","size":1000000000000,"model":"USB Bridge","temperature":0,"disk_type":"USB","serial":"","path":"/dev/sdd","children_number":1}]}}"#
    )

    static let pathlessPhysicalDisk = data(
        #"{"success":200,"message":"ok","data":{"disks":[{"name":"mmcblk0","size":128000000000,"model":"","health":"true","temperature":0,"disk_type":"","serial":"","path":""}]}}"#
    )

    static let ambiguousPhysicalDisks = data(
        #"{"success":200,"message":"ok","data":{"disks":[{"name":"sda","health":"true","temperature":0},{"name":"SDA","health":"true","temperature":0}]}}"#
    )

    static let userStatus = data(
        #"{"success":200,"message":"ok","data":{"initialized":true,"key":"","gpus":0}}"#
    )

    static let login = data(
        #"{"success":200,"message":"ok","data":{"token":{"access_token":"raw.access.token","refresh_token":"raw.refresh.token","expires_at":1800000000},"user":{"id":1,"username":"casa"}}}"#
    )

    static let refresh = data(
        #"{"success":200,"message":"ok","data":{"access_token":"refreshed.access","refresh_token":"refreshed.refresh","expires_at":1800000100}}"#
    )

    static let apps = data(
        #"{"data":{"syncthing":{"store_info":{"title":{"en_us":"Syncthing"},"icon":"https://example.test/syncthing.png","scheme":"http","hostname":"","port_map":"8384","index":"/"},"compose":{"name":"syncthing"},"status":"running"}}}"#
    )

    static let blankTitleApp = data(
        #"{"data":{"pihole":{"store_info":{"title":{"en_us":"   "},"scheme":"http","hostname":"rpi.local","port_map":"8080","index":"/admin"},"compose":{"name":"app"},"status":"running"}}}"#
    )

    static let statusAccepted = data(
        #"{"message":"compose app status is being changed asynchronously"}"#
    )

    static let files = data(
        #"{"success":200,"message":"ok","data":{"content":[{"name":"note.txt","path":"/DATA/My Documents/note.txt","is_dir":false,"size":42,"modified":"2026-08-12T18:00:00Z","date":"2026-08-12T18:00:00Z"},{"name":"Photos","path":"/DATA/My Documents/Photos","is_dir":true,"size":0,"modified":"2026-08-11T17:00:00Z","date":"2026-08-11T17:00:00Z"}]}}"#
    )

    static let serverRootFiles = data(
        #"{"success":200,"message":"ok","data":{"content":[{"name":"etc","path":"/etc","is_dir":true,"size":4096,"modified":"2026-08-12T18:00:00Z","date":"2026-08-12T18:00:00Z"},{"name":"DATA","path":"/DATA","is_dir":true,"size":4096,"modified":"2026-08-12T18:00:00Z","date":"2026-08-12T18:00:00Z"}]}}"#
    )

    static let v1Success = data(
        #"{"success":200,"message":"ok","data":null}"#
    )

    private static func data(_ value: String) -> Data {
        Data(value.utf8)
    }
}

private enum CasaOSURLProtocolStubError: Error {
    case unexpectedPath(String?)
}

private actor UploadBatchTestRecorder {
    private var names: [String] = []
    private var activeCount = 0
    private var maximumActiveCount = 0

    func begin(_ name: String) {
        names.append(name)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func finish() {
        activeCount -= 1
    }

    func snapshot() -> (names: [String], activeCount: Int, maximumActiveCount: Int) {
        (names, activeCount, maximumActiveCount)
    }
}

private final class UploadBatchReadThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValue: Bool?

    var wasMainThread: Bool? {
        lock.withLock { recordedValue }
    }

    func record(isMainThread: Bool) {
        lock.withLock {
            recordedValue = isMainThread
        }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            recordedRequests.append(request)
        }
    }
}

private final class CasaOSURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installedHandler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            installedHandler = handler
        }
    }

    static func reset() {
        lock.withLock {
            installedHandler = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.installedHandler }
        guard let handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        do {
            var capturedRequest = request
            if capturedRequest.httpBody == nil,
               let stream = capturedRequest.httpBodyStream {
                capturedRequest.httpBody = try Self.readBody(from: stream)
            }
            let (response, data) = try handler(capturedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let value = response.value(forHTTPHeaderField: "X-CasaNative-Test-Chunk-Size"),
               let chunkSize = Int(value), chunkSize > 0 {
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunkSize, data.count)
                    client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                    offset = end
                }
            } else {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(from stream: InputStream) throws -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
    }
}
