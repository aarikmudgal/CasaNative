import XCTest
@testable import CasaNative

final class SMARTDriveHealthTests: XCTestCase {
    func testDevicePathValidationAcceptsOnlyOneSimplePhysicalPath() throws {
        XCTAssertEqual(
            try SSHSMARTDriveHealthController.validatedDevicePath(" /dev/sdd \n"),
            "/dev/sdd"
        )
        XCTAssertEqual(
            try SSHSMARTDriveHealthController.validatedDevicePath("/dev/nvme0n1"),
            "/dev/nvme0n1"
        )

        for path in [
            "", "/dev/", "/dev/.", "/dev/..", "/dev/-d", "/dev/_sdd",
            "/dev/disk/by-id/example", "/dev/sdd;reboot", "/tmp/sdd",
        ] {
            XCTAssertThrowsError(
                try SSHSMARTDriveHealthController.validatedDevicePath(path),
                "Expected rejection for \(path)"
            ) { error in
                XCTAssertEqual(error as? SMARTDriveError, .invalidDevicePath)
            }
        }
    }

    func testScriptsSeparateStandbySafePreflightFromExplicitWake() throws {
        let preflight = SMARTDriveScripts.check(
            devicePath: "/dev/sdd",
            standbySafe: true
        )
        let wake = SMARTDriveScripts.check(
            devicePath: "/dev/sdd",
            standbySafe: false
        )
        let preflightScript = try decodedScript(preflight)
        let wakeScript = try decodedScript(wake)

        XCTAssertTrue(preflightScript.contains("readlink -f -- \"$device\""))
        XCTAssertTrue(preflightScript.contains("[ -b \"$resolved\" ]"))
        XCTAssertTrue(preflightScript.contains("smartctl -a -j -n standby -- \"$resolved\""))
        XCTAssertTrue(wakeScript.contains("smartctl -a -j -- \"$resolved\""))
        XCTAssertFalse(wakeScript.contains("-n standby"))
        XCTAssertTrue(preflight.command.contains(" 12s /bin/sh"))
        XCTAssertTrue(wake.command.contains(" 30s /bin/sh"))
        XCTAssertEqual(preflight.timeoutSeconds, 16)
        XCTAssertEqual(wake.timeoutSeconds, 35)
        XCTAssertEqual(preflight.maximumOutputBytes, 128 * 1_024)
        XCTAssertEqual(wake.maximumOutputBytes, 128 * 1_024)
    }

    func testPrivilegedPasswordStaysOnlyInStandardInput() {
        let base = SMARTDriveScripts.check(
            devicePath: "/dev/sdd",
            standbySafe: true
        )
        let request = SMARTDriveScripts.privileged(base, password: "secret value")

        XCTAssertTrue(request.command.hasPrefix("/usr/bin/sudo -S -p ''"))
        XCTAssertFalse(request.command.contains("secret value"))
        XCTAssertEqual(
            String(decoding: request.standardInput, as: UTF8.self),
            "secret value\n"
        )
        XCTAssertEqual(
            SMARTDriveScripts.sudoNonInteractiveCheck.command,
            "/usr/bin/sudo -n /usr/bin/true"
        )
    }

    func testATAFixturePreservesIdentityHealthAndSelectedRawMetrics() throws {
        let metrics = try SMARTDriveJSONParser.parse(
            Data(Self.ataFixture.utf8),
            requestedDevicePath: "/dev/sdd"
        )

        XCTAssertEqual(metrics.devicePath, "/dev/sdd")
        XCTAssertEqual(metrics.deviceType, "sat")
        XCTAssertEqual(metrics.protocolName, "ATA")
        XCTAssertEqual(metrics.modelName, "SanDisk Extreme 55AE")
        XCTAssertEqual(metrics.serialNumber, "AA0102030405")
        XCTAssertEqual(metrics.firmwareVersion, "1012")
        XCTAssertEqual(metrics.capacityBytes, 2_000_398_934_016)
        XCTAssertEqual(metrics.overallHealthPassed, true)
        XCTAssertEqual(metrics.temperatureCelsius, 31)
        XCTAssertEqual(
            metrics.metrics.map(\.kind),
            [
                .ataLife, .powerOnHours, .powerCycleCount,
                .reallocatedSectorCount, .currentPendingSectorCount,
                .offlineUncorrectableSectorCount, .udmaCRCErrorCount,
            ]
        )
        XCTAssertEqual(
            metrics.metrics.first(where: { $0.kind == .ataLife })?.value,
            "98"
        )
        XCTAssertEqual(
            metrics.metrics.first(where: { $0.kind == .ataLife })?.unit,
            "%"
        )
        XCTAssertNil(metrics.metrics.first(where: { $0.label == "Unknown vendor field" }))
    }

    func testNVMeFixtureUsesDirectHealthLogValuesWithoutConversions() throws {
        let metrics = try SMARTDriveJSONParser.parse(
            Data(Self.nvmeFixture.utf8),
            requestedDevicePath: "/dev/nvme0n1"
        )

        XCTAssertEqual(metrics.deviceType, "nvme")
        XCTAssertEqual(metrics.protocolName, "NVMe")
        XCTAssertEqual(metrics.temperatureCelsius, 40)
        XCTAssertEqual(
            metrics.metrics.map(\.kind),
            [
                .percentageUsed, .availableSpare, .powerOnHours,
                .powerCycleCount, .criticalWarning, .mediaErrors,
                .dataUnitsRead, .dataUnitsWritten,
            ]
        )
        XCTAssertEqual(Self.metric(.percentageUsed, in: metrics)?.value, "7")
        XCTAssertEqual(Self.metric(.percentageUsed, in: metrics)?.unit, "%")
        XCTAssertEqual(Self.metric(.availableSpare, in: metrics)?.value, "99")
        XCTAssertEqual(Self.metric(.powerOnHours, in: metrics)?.value, "555")
        XCTAssertEqual(Self.metric(.dataUnitsRead, in: metrics)?.value, "123456789")
        XCTAssertEqual(Self.metric(.dataUnitsRead, in: metrics)?.unit, "data units")
    }

    func testParserRejectsEmptyOrWrongDeviceJSON() {
        XCTAssertThrowsError(
            try SMARTDriveJSONParser.parse(
                Data("{}".utf8),
                requestedDevicePath: "/dev/sdd"
            )
        ) { error in
            XCTAssertEqual(error as? SMARTDriveError, .invalidResponse)
        }
        XCTAssertThrowsError(
            try SMARTDriveJSONParser.parse(
                Data(Self.ataFixture.utf8),
                requestedDevicePath: "/dev/sde"
            )
        ) { error in
            XCTAssertEqual(error as? SMARTDriveError, .invalidResponse)
        }
    }

    func testParserReportsUSBDeviceTypeRequirementWithoutGuessing() {
        let fixture = """
        {
          "json_format_version": [1, 0],
          "smartctl": {"exit_status": 1},
          "device": {"name": "/dev/sdd"},
          "messages": [{
            "string": "Unknown USB bridge [0x1234:0x5678]. Please specify device type with the -d option."
          }]
        }
        """
        XCTAssertThrowsError(
            try SMARTDriveJSONParser.parse(
                Data(fixture.utf8),
                requestedDevicePath: "/dev/sdd"
            )
        ) { error in
            guard case let SMARTDriveError.deviceTypeRequired(detail) = error else {
                return XCTFail("Expected deviceTypeRequired, got \(error)")
            }
            XCTAssertTrue(detail.contains("-d option"))
        }
    }

    func testPreflightRecognizesStandbyWithoutParsingMetrics() async throws {
        let executor = ScriptedSMARTSSHExecutor(results: [
            Self.result(status: 0),
            Self.result(error: "Device is in STANDBY mode, exit(2)\n", status: 2),
        ])
        let controller = try await makeController(executor: executor)

        let result = try await controller.preflight(devicePath: "/dev/sdd")

        XCTAssertEqual(result.powerState, .standby)
        XCTAssertNil(result.metrics)
        XCTAssertTrue(result.requiresWakeConfirmation)
        let requests = await executor.requestsSnapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(try decodedScript(requests[1]).contains("-n standby"))
    }

    func testPreflightReturnsValidMetricsDespiteSmartctlHealthBitmaskExit() async throws {
        let executor = ScriptedSMARTSSHExecutor(results: [
            Self.result(status: 0),
            Self.result(output: Self.ataFixture, status: 8),
        ])
        let controller = try await makeController(executor: executor)

        let result = try await controller.preflight(devicePath: "/dev/sdd")

        XCTAssertEqual(result.powerState, .awake)
        XCTAssertEqual(result.metrics?.overallHealthPassed, true)
        XCTAssertFalse(result.requiresWakeConfirmation)
    }

    func testExplicitWakeOmitsStandbyGuardAndUsesConfirmedExactDrive() async throws {
        let executor = ScriptedSMARTSSHExecutor(results: [
            Self.result(status: 1),
            Self.result(output: Self.ataFixture, status: 0),
        ])
        let controller = try await makeController(executor: executor)

        let metrics = try await controller.wakeAndFetchMetrics(
            devicePath: "/dev/sdd",
            confirmation: .userConfirmed
        )

        XCTAssertEqual(metrics.devicePath, "/dev/sdd")
        let requests = await executor.requestsSnapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(try decodedScript(requests[1]).contains("-n standby"))
        XCTAssertEqual(
            String(decoding: requests[1].standardInput, as: UTF8.self),
            "password\n"
        )
        XCTAssertFalse(requests[1].command.contains("password"))
    }

    func testInvalidPathAndUnsafePasswordFailBeforeSMARTCommand() async throws {
        let executor = ScriptedSMARTSSHExecutor(results: [])
        let controller = try await makeController(
            executor: executor,
            password: "bad\npassword"
        )

        await XCTAssertThrowsSMARTError(.invalidDevicePath) {
            _ = try await controller.preflight(devicePath: "/dev/sdd;reboot")
        }
        await XCTAssertThrowsSMARTError(.invalidPrivilegedPassword) {
            _ = try await controller.preflight(devicePath: "/dev/sdd")
        }
        let requests = await executor.requestsSnapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    private func makeController(
        executor: ScriptedSMARTSSHExecutor,
        password: String = "password"
    ) async throws -> SSHSMARTDriveHealthController {
        let url = try XCTUnwrap(URL(string: "https://casa.test"))
        let store = InMemorySSHCredentialStore()
        try await store.storeSeparate(
            SSHCredentials(username: "tester", password: password),
            for: url
        )
        return SSHSMARTDriveHealthController(
            serverURL: url,
            credentialMode: .separate,
            credentialStore: store,
            executor: executor
        )
    }

    private func decodedScript(_ request: SSHCommandRequest) throws -> String {
        let marker = "/usr/bin/printf '%s' '"
        guard let markerRange = request.command.range(of: marker),
              let end = request.command[markerRange.upperBound...].firstIndex(of: "'") else {
            throw SMARTDriveError.invalidResponse
        }
        let encoded = String(request.command[markerRange.upperBound..<end])
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        return String(decoding: data, as: UTF8.self)
    }

    private static func metric(
        _ kind: SMARTDriveMetric.Kind,
        in metrics: SMARTDriveMetrics
    ) -> SMARTDriveMetric? {
        metrics.metrics.first { $0.kind == kind }
    }

    private static func result(
        output: String = "",
        error: String = "",
        status: Int
    ) -> SSHCommandResult {
        SSHCommandResult(
            standardOutput: Data(output.utf8),
            standardError: Data(error.utf8),
            exitStatus: status
        )
    }

    private static let ataFixture = """
    {
      "json_format_version": [1, 0],
      "smartctl": {"version": [7, 4], "exit_status": 0},
      "device": {"name": "/dev/sdd", "type": "sat", "protocol": "ATA"},
      "model_name": "SanDisk Extreme 55AE",
      "serial_number": "AA0102030405",
      "firmware_version": "1012",
      "user_capacity": {"bytes": 2000398934016},
      "smart_status": {"passed": true},
      "temperature": {"current": 31},
      "power_on_time": {"hours": 4321},
      "power_cycle_count": 42,
      "ata_smart_attributes": {"table": [
        {"id": 5, "name": "Reallocated_Sector_Ct", "raw": {"value": 2}},
        {"id": 197, "name": "Current_Pending_Sector", "raw": {"value": 3}},
        {"id": 198, "name": "Offline_Uncorrectable", "raw": {"value": 4}},
        {"id": 199, "name": "UDMA_CRC_Error_Count", "raw": {"value": 5}},
        {"id": 202, "name": "Percent_Lifetime_Remain", "value": 98, "raw": {"value": 2}},
        {"id": 250, "name": "Unknown_Vendor_Field", "raw": {"value": 999}}
      ]}
    }
    """

    private static let nvmeFixture = """
    {
      "json_format_version": [1, 0],
      "smartctl": {"version": [7, 4], "exit_status": 0},
      "device": {"name": "/dev/nvme0n1", "type": "nvme", "protocol": "NVMe"},
      "model_name": "Demo NVMe",
      "serial_number": "NVME-DEMO",
      "user_capacity": {"bytes": 1000204886016},
      "smart_status": {"passed": true},
      "nvme_smart_health_information_log": {
        "critical_warning": 0,
        "temperature": 40,
        "available_spare": 99,
        "percentage_used": 7,
        "data_units_read": 123456789,
        "data_units_written": 987654321,
        "power_cycles": 23,
        "power_on_hours": 555,
        "media_errors": 1
      }
    }
    """
}

private actor ScriptedSMARTSSHExecutor: SSHCommandExecuting {
    private var remaining: [SSHCommandResult]
    private var requests: [SSHCommandRequest] = []

    init(results: [SSHCommandResult]) {
        remaining = results
    }

    func execute(
        _ request: SSHCommandRequest,
        credentials: SSHCredentials
    ) async throws -> SSHCommandResult {
        requests.append(request)
        guard !remaining.isEmpty else {
            throw SMARTDriveError.invalidResponse
        }
        return remaining.removeFirst()
    }

    func requestsSnapshot() -> [SSHCommandRequest] {
        requests
    }
}

private func XCTAssertThrowsSMARTError<T: Sendable>(
    _ expected: SMARTDriveError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? SMARTDriveError, expected, file: file, line: line)
    }
}
