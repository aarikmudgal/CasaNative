import CoreFoundation
import Foundation

enum SMARTDrivePowerState: Equatable, Sendable {
    case awake
    case standby
    case unknown
}

enum SMARTDriveWakeConfirmation: Equatable, Sendable {
    case userConfirmed
}

struct SMARTDrivePreflight: Equatable, Sendable {
    let devicePath: String
    let powerState: SMARTDrivePowerState
    let metrics: SMARTDriveMetrics?
    let detail: String?

    var requiresWakeConfirmation: Bool {
        powerState != .awake
    }
}

struct SMARTDriveMetrics: Equatable, Sendable {
    let devicePath: String
    let deviceType: String?
    let protocolName: String?
    let modelName: String?
    let serialNumber: String?
    let firmwareVersion: String?
    let capacityBytes: UInt64?
    let overallHealthPassed: Bool?
    let temperatureCelsius: Double?
    let metrics: [SMARTDriveMetric]
}

struct SMARTDriveMetric: Identifiable, Equatable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case percentageUsed
        case availableSpare
        case ataLife
        case powerOnHours
        case powerCycleCount
        case reallocatedSectorCount
        case currentPendingSectorCount
        case offlineUncorrectableSectorCount
        case udmaCRCErrorCount
        case criticalWarning
        case mediaErrors
        case dataUnitsRead
        case dataUnitsWritten
    }

    enum Source: Equatable, Sendable {
        case nvmeHealthLog(field: String)
        case ataAttribute(id: Int, name: String)
        case smartctl(field: String)
    }

    var id: String { "\(kind.rawValue):\(label)" }

    let kind: Kind
    let label: String
    let value: String
    let unit: String?
    let source: Source
}

actor MockSMARTDriveHealthController: SMARTDriveHealthControlling {
    private let powerState: SMARTDrivePowerState
    private let metricsByPath: [String: SMARTDriveMetrics]

    init(
        powerState: SMARTDrivePowerState = .awake,
        metrics: [SMARTDriveMetrics] = []
    ) {
        self.powerState = powerState
        metricsByPath = Dictionary(
            uniqueKeysWithValues: metrics.map { ($0.devicePath, $0) }
        )
    }

    func preflight(devicePath: String) async throws -> SMARTDrivePreflight {
        let path = try SSHSMARTDriveHealthController.validatedDevicePath(devicePath)
        let metrics = metricsByPath[path] ?? Self.demoMetrics(devicePath: path)
        return SMARTDrivePreflight(
            devicePath: path,
            powerState: powerState,
            metrics: powerState == .awake ? metrics : nil,
            detail: powerState == .awake ? nil : "Mock drive is sleeping."
        )
    }

    func wakeAndFetchMetrics(
        devicePath: String,
        confirmation: SMARTDriveWakeConfirmation
    ) async throws -> SMARTDriveMetrics {
        _ = confirmation
        let path = try SSHSMARTDriveHealthController.validatedDevicePath(devicePath)
        return metricsByPath[path] ?? Self.demoMetrics(devicePath: path)
    }

    private static func demoMetrics(devicePath: String) -> SMARTDriveMetrics {
        SMARTDriveMetrics(
            devicePath: devicePath,
            deviceType: "sat",
            protocolName: "ATA",
            modelName: "Demo SMART Drive",
            serialNumber: "DEMO-SMART",
            firmwareVersion: "1.0",
            capacityBytes: 2_000_398_934_016,
            overallHealthPassed: true,
            temperatureCelsius: 31,
            metrics: [
                SMARTDriveMetric(
                    kind: .powerOnHours,
                    label: "Power-on hours",
                    value: "1234",
                    unit: "hours",
                    source: .smartctl(field: "power_on_time.hours")
                ),
            ]
        )
    }
}

protocol SMARTDriveHealthControlling: Sendable {
    /// Standby-safe. Never omits smartctl's `-n standby` guard.
    func preflight(devicePath: String) async throws -> SMARTDrivePreflight

    /// May wake one drive. Caller must obtain an on-screen user confirmation first.
    func wakeAndFetchMetrics(
        devicePath: String,
        confirmation: SMARTDriveWakeConfirmation
    ) async throws -> SMARTDriveMetrics
}

enum SMARTDriveError: LocalizedError, Equatable, Sendable {
    case invalidDevicePath
    case missingCredentials
    case invalidPrivilegedPassword
    case smartctlUnavailable
    case deviceTypeRequired(String)
    case commandFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidDevicePath:
            "Select one physical drive with a simple /dev device path."
        case .missingCredentials:
            "No SSH credentials are saved for this server."
        case .invalidPrivilegedPassword:
            "The saved SSH password cannot be used safely with sudo. Save a password without line breaks."
        case .smartctlUnavailable:
            "smartctl is not installed on this server."
        case let .deviceTypeRequired(detail):
            "smartctl requires an explicit device type for this drive or USB bridge. Casa Native did not guess one. \(detail)"
        case let .commandFailed(detail):
            "The SMART check could not complete. \(detail)"
        case .invalidResponse:
            "smartctl returned an invalid JSON response."
        }
    }
}

actor SSHSMARTDriveHealthController: SMARTDriveHealthControlling {
    private let serverURL: URL
    private let credentialMode: SSHCredentialMode
    private let credentialStore: any SSHCredentialStoring
    private let executor: any SSHCommandExecuting

    init(
        serverURL: URL,
        credentialMode: SSHCredentialMode,
        credentialStore: any SSHCredentialStoring,
        hostKeyStore: any SSHPinnedHostKeyStoring = SSHHostKeyStore(),
        hostKeyConfirmation: @escaping SSHHostKeyVerifier.Confirmation
    ) {
        self.serverURL = serverURL
        self.credentialMode = credentialMode
        self.credentialStore = credentialStore
        do {
            executor = try NIOSSHCommandExecutor(
                serverURL: serverURL,
                hostKeyStore: hostKeyStore,
                hostKeyConfirmation: hostKeyConfirmation
            )
        } catch {
            executor = FailingSMARTSSHCommandExecutor(error: error)
        }
    }

    init(
        serverURL: URL,
        credentialMode: SSHCredentialMode,
        credentialStore: any SSHCredentialStoring,
        executor: any SSHCommandExecuting
    ) {
        self.serverURL = serverURL
        self.credentialMode = credentialMode
        self.credentialStore = credentialStore
        self.executor = executor
    }

    func preflight(devicePath: String) async throws -> SMARTDrivePreflight {
        let path = try Self.validatedDevicePath(devicePath)
        let result = try await execute(
            SMARTDriveScripts.check(devicePath: path, standbySafe: true)
        )

        if Self.isStandby(result) {
            return SMARTDrivePreflight(
                devicePath: path,
                powerState: .standby,
                metrics: nil,
                detail: "Drive is in standby. Wake it only after confirmation."
            )
        }

        do {
            let metrics = try SMARTDriveJSONParser.parse(
                result.standardOutput,
                requestedDevicePath: path
            )
            return SMARTDrivePreflight(
                devicePath: path,
                powerState: .awake,
                metrics: metrics,
                detail: nil
            )
        } catch SMARTDriveError.invalidResponse where result.exitStatus != 0 {
            try Self.throwCommandError(result)
            throw SMARTDriveError.invalidResponse
        }
    }

    func wakeAndFetchMetrics(
        devicePath: String,
        confirmation: SMARTDriveWakeConfirmation
    ) async throws -> SMARTDriveMetrics {
        _ = confirmation
        let path = try Self.validatedDevicePath(devicePath)
        let result = try await execute(
            SMARTDriveScripts.check(devicePath: path, standbySafe: false)
        )
        do {
            return try SMARTDriveJSONParser.parse(
                result.standardOutput,
                requestedDevicePath: path
            )
        } catch SMARTDriveError.invalidResponse where result.exitStatus != 0 {
            try Self.throwCommandError(result)
            throw SMARTDriveError.invalidResponse
        }
    }

    private func execute(_ unprivilegedRequest: SSHCommandRequest) async throws -> SSHCommandResult {
        guard let credentials = try await credentialStore.load(
            mode: credentialMode,
            for: serverURL
        ) else {
            throw SMARTDriveError.missingCredentials
        }
        guard !credentials.password.contains("\n"),
              !credentials.password.contains("\r") else {
            throw SMARTDriveError.invalidPrivilegedPassword
        }

        let noPassword = try await executor.execute(
            SMARTDriveScripts.sudoNonInteractiveCheck,
            credentials: credentials
        )
        let request = SMARTDriveScripts.privileged(
            unprivilegedRequest,
            password: noPassword.exitStatus == 0 ? nil : credentials.password
        )
        return try await executor.execute(request, credentials: credentials)
    }

    private static func isStandby(_ result: SSHCommandResult) -> Bool {
        let combined = result.outputString + "\n" + result.sanitizedError
        return combined.localizedCaseInsensitiveContains("device is in standby mode")
            || combined.localizedCaseInsensitiveContains("device is in standby")
    }

    private static func throwCommandError(_ result: SSHCommandResult) throws {
        let detail = result.sanitizedError.isEmpty
            ? result.outputString.trimmingCharacters(in: .whitespacesAndNewlines)
            : result.sanitizedError
        let lower = detail.lowercased()
        if lower.contains("please specify device type with the -d option")
            || lower.contains("specify device type with the -d option")
            || lower.contains("unknown usb bridge") {
            throw SMARTDriveError.deviceTypeRequired(String(detail.prefix(512)))
        }
        if lower.contains("smartctl: not found")
            || lower.contains("smartctl: command not found") {
            throw SMARTDriveError.smartctlUnavailable
        }
        throw SMARTDriveError.commandFailed(
            detail.isEmpty ? "smartctl exited with status \(result.exitStatus)." : String(detail.prefix(512))
        )
    }

    static func validatedDevicePath(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/dev/"), path.count > 5 else {
            throw SMARTDriveError.invalidDevicePath
        }
        let name = path.dropFirst(5)
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"
        )
        guard name != ".", name != "..",
              name.first?.isASCII == true,
              (name.first?.isLetter == true || name.first?.isNumber == true),
              !name.contains("/"),
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SMARTDriveError.invalidDevicePath
        }
        return path
    }
}

enum SMARTDriveScripts {
    static let sudoNonInteractiveCheck = SSHCommandRequest(
        command: "/usr/bin/sudo -n /usr/bin/true",
        timeoutSeconds: 5,
        maximumOutputBytes: 4 * 1_024
    )

    static func check(devicePath: String, standbySafe: Bool) -> SSHCommandRequest {
        precondition((try? SSHSMARTDriveHealthController.validatedDevicePath(devicePath)) == devicePath)
        let standby = standbySafe ? " -n standby" : ""
        let script = """
        set -eu
        device='\(devicePath)'
        resolved=$(/usr/bin/readlink -f -- "$device")
        case "$resolved" in /dev/*) ;; *) echo 'Invalid resolved device path' >&2; exit 64;; esac
        [ -b "$resolved" ] || { echo 'Selected path is not a block device' >&2; exit 64; }
        exec /usr/sbin/smartctl -a -j\(standby) -- "$resolved"
        """
        return SSHCommandRequest(
            command: encodedShell(script, remoteTimeoutSeconds: standbySafe ? 12 : 30),
            timeoutSeconds: standbySafe ? 16 : 35,
            maximumOutputBytes: 128 * 1_024
        )
    }

    static func privileged(
        _ request: SSHCommandRequest,
        password: String?
    ) -> SSHCommandRequest {
        let command: String
        var input = Data()
        if let password {
            command = "/usr/bin/sudo -S -p '' \(request.command)"
            input.append(Data(password.utf8))
            input.append(0x0A)
        } else {
            command = "/usr/bin/sudo -n \(request.command)"
        }
        return SSHCommandRequest(
            command: command,
            standardInput: input,
            timeoutSeconds: request.timeoutSeconds,
            maximumOutputBytes: request.maximumOutputBytes
        )
    }

    private static func encodedShell(
        _ script: String,
        remoteTimeoutSeconds: Int
    ) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        let decode = "/usr/bin/printf '%s' '\(encoded)' | /usr/bin/base64 -d | /bin/sh"
        return "/usr/bin/timeout --signal=TERM --kill-after=3s \(remoteTimeoutSeconds)s /bin/sh -c \"\(decode)\""
    }
}

enum SMARTDriveJSONParser {
    static func parse(
        _ data: Data,
        requestedDevicePath: String
    ) throws -> SMARTDriveMetrics {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SMARTDriveError.invalidResponse
            }
            root = object
        } catch let error as SMARTDriveError {
            throw error
        } catch {
            throw SMARTDriveError.invalidResponse
        }

        if let messages = root["messages"] as? [[String: Any]],
           let typeMessage = messages.compactMap({ $0["string"] as? String }).first(where: {
               let value = $0.lowercased()
               return value.contains("specify device type with the -d option")
                   || value.contains("unknown usb bridge")
           }) {
            throw SMARTDriveError.deviceTypeRequired(String(typeMessage.prefix(512)))
        }

        let device = dictionary(root["device"])
        let smartctl = dictionary(root["smartctl"])
        let capacity = dictionary(root["user_capacity"])
        let smartStatus = dictionary(root["smart_status"])
        let temperature = dictionary(root["temperature"])
        let nvme = dictionary(root["nvme_smart_health_information_log"])
        let powerOn = dictionary(root["power_on_time"])
        guard root["json_format_version"] is [Any] || !smartctl.isEmpty,
              let reportedPath = string(device["name"]),
              (reportedPath as NSString).lastPathComponent
                == (requestedDevicePath as NSString).lastPathComponent else {
            throw SMARTDriveError.invalidResponse
        }
        var rows: [SMARTDriveMetric] = []

        appendNumeric(
            value: numericString(powerOn["hours"]),
            kind: .powerOnHours,
            label: "Power-on hours",
            unit: "hours",
            source: .smartctl(field: "power_on_time.hours"),
            to: &rows
        )
        appendNumeric(
            value: numericString(root["power_cycle_count"]),
            kind: .powerCycleCount,
            label: "Power cycles",
            unit: nil,
            source: .smartctl(field: "power_cycle_count"),
            to: &rows
        )
        appendNumeric(
            value: numericString(nvme["power_on_hours"]),
            kind: .powerOnHours,
            label: "Power-on hours",
            unit: "hours",
            source: .nvmeHealthLog(field: "power_on_hours"),
            to: &rows
        )
        appendNumeric(
            value: numericString(nvme["power_cycles"]),
            kind: .powerCycleCount,
            label: "Power cycles",
            unit: nil,
            source: .nvmeHealthLog(field: "power_cycles"),
            to: &rows
        )

        appendNumeric(
            value: numericString(nvme["percentage_used"]),
            kind: .percentageUsed,
            label: "Percentage used",
            unit: "%",
            source: .nvmeHealthLog(field: "percentage_used"),
            to: &rows
        )
        appendNumeric(
            value: numericString(nvme["available_spare"]),
            kind: .availableSpare,
            label: "Available spare",
            unit: "%",
            source: .nvmeHealthLog(field: "available_spare"),
            to: &rows
        )
        appendNumeric(
            value: numericString(nvme["critical_warning"]),
            kind: .criticalWarning,
            label: "Critical warning",
            unit: nil,
            source: .nvmeHealthLog(field: "critical_warning"),
            to: &rows
        )
        appendNumeric(
            value: numericString(nvme["media_errors"]),
            kind: .mediaErrors,
            label: "Media errors",
            unit: nil,
            source: .nvmeHealthLog(field: "media_errors"),
            to: &rows
        )
        appendNumeric(
            value: numericString(nvme["data_units_read"]),
            kind: .dataUnitsRead,
            label: "Data units read",
            unit: "data units",
            source: .nvmeHealthLog(field: "data_units_read"),
            to: &rows
        )
        appendNumeric(
            value: numericString(nvme["data_units_written"]),
            kind: .dataUnitsWritten,
            label: "Data units written",
            unit: "data units",
            source: .nvmeHealthLog(field: "data_units_written"),
            to: &rows
        )

        appendATAAttributes(root, to: &rows)

        let nvmeTemperature = integer(nvme["temperature"])
        let reportedTemperature = number(temperature["current"])
            ?? nvmeTemperature.map(Double.init)

        let deviceType = string(device["type"])
        let protocolName = string(device["protocol"])
        let modelName = string(root["model_name"]) ?? string(root["model_family"])
        let serialNumber = string(root["serial_number"])
        let firmwareVersion = string(root["firmware_version"])
        let capacityBytes = unsignedInteger(capacity["bytes"])
        let overallHealthPassed = boolean(smartStatus["passed"])
        guard deviceType != nil || protocolName != nil || modelName != nil
                || serialNumber != nil || firmwareVersion != nil
                || capacityBytes != nil || overallHealthPassed != nil
                || reportedTemperature != nil || !rows.isEmpty else {
            throw SMARTDriveError.invalidResponse
        }

        return SMARTDriveMetrics(
            devicePath: requestedDevicePath,
            deviceType: deviceType,
            protocolName: protocolName,
            modelName: modelName,
            serialNumber: serialNumber,
            firmwareVersion: firmwareVersion,
            capacityBytes: capacityBytes,
            overallHealthPassed: overallHealthPassed,
            temperatureCelsius: reportedTemperature,
            metrics: ordered(rows)
        )
    }

    private static func appendATAAttributes(
        _ root: [String: Any],
        to rows: inout [SMARTDriveMetric]
    ) {
        let table = dictionary(dictionary(root["ata_smart_attributes"])["table"])
        let rawTable = dictionary(root["ata_smart_attributes"])["table"] as? [[String: Any]]
        let attributes = rawTable ?? (table.isEmpty ? [] : [table])
        for attribute in attributes {
            guard let id = integer(attribute["id"]),
                  let idValue = Int(exactly: id),
                  let name = string(attribute["name"]) else { continue }
            let raw = dictionary(attribute["raw"])
            guard let rawValue = numericString(raw["value"]) else { continue }
            let normalizedName = name.lowercased()
            let kind: SMARTDriveMetric.Kind?
            let label: String
            let unit: String?
            let value: String?

            switch idValue {
            case 5:
                kind = .reallocatedSectorCount
                label = "Reallocated sectors"
                unit = nil
                value = rawValue
            case 9 where normalizedName.contains("power_on"):
                kind = .powerOnHours
                label = "Power-on hours"
                unit = "hours"
                value = rawValue
            case 12 where normalizedName.contains("power_cycle"):
                kind = .powerCycleCount
                label = "Power cycles"
                unit = nil
                value = rawValue
            case 197:
                kind = .currentPendingSectorCount
                label = "Current pending sectors"
                unit = nil
                value = rawValue
            case 198:
                kind = .offlineUncorrectableSectorCount
                label = "Offline uncorrectable sectors"
                unit = nil
                value = rawValue
            case 199:
                kind = .udmaCRCErrorCount
                label = "UDMA CRC errors"
                unit = nil
                value = rawValue
            case 202 where normalizedName == "percent_lifetime_remain":
                kind = .ataLife
                label = "Lifetime remaining"
                unit = "%"
                value = numericString(attribute["value"])
            case 231 where normalizedName == "ssd_life_left":
                kind = .ataLife
                label = "SSD life left"
                unit = "%"
                value = numericString(attribute["value"])
            case 233 where normalizedName == "media_wearout_indicator":
                kind = .ataLife
                label = "Media wearout indicator"
                unit = nil
                value = numericString(attribute["value"])
            default:
                kind = nil
                label = ""
                unit = nil
                value = nil
            }

            guard let kind, let value else { continue }
            rows.append(SMARTDriveMetric(
                kind: kind,
                label: label,
                value: value,
                unit: unit,
                source: .ataAttribute(id: idValue, name: name)
            ))
        }
    }

    private static func ordered(_ values: [SMARTDriveMetric]) -> [SMARTDriveMetric] {
        let order: [SMARTDriveMetric.Kind] = [
            .percentageUsed, .availableSpare, .ataLife,
            .powerOnHours, .powerCycleCount,
            .reallocatedSectorCount, .currentPendingSectorCount,
            .offlineUncorrectableSectorCount, .udmaCRCErrorCount,
            .criticalWarning, .mediaErrors, .dataUnitsRead, .dataUnitsWritten,
        ]
        var seen = Set<SMARTDriveMetric.Kind>()
        return values
            .sorted {
                (order.firstIndex(of: $0.kind) ?? order.count)
                    < (order.firstIndex(of: $1.kind) ?? order.count)
            }
            .filter { seen.insert($0.kind).inserted }
    }

    private static func appendNumeric(
        value: String?,
        kind: SMARTDriveMetric.Kind,
        label: String,
        unit: String?,
        source: SMARTDriveMetric.Source,
        to rows: inout [SMARTDriveMetric]
    ) {
        guard let value else { return }
        rows.append(SMARTDriveMetric(
            kind: kind,
            label: label,
            value: value,
            unit: unit,
            source: source
        ))
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }

    private static func numericString(_ value: Any?) -> String? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.int64Value >= 0 else { return nil }
        return number.uint64Value
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

private struct FailingSMARTSSHCommandExecutor: SSHCommandExecuting {
    private let description: String

    init(error: any Error) {
        description = error.localizedDescription
    }

    func execute(
        _ request: SSHCommandRequest,
        credentials: SSHCredentials
    ) async throws -> SSHCommandResult {
        throw SMARTDriveError.commandFailed(description)
    }
}
