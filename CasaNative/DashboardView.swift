import Combine
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var summary: ServerSummary?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let refreshInterval: Duration = .seconds(10)

    private var client: any CasaOSClient { model.client }

    var body: some View {
        List {
            if let summary {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 42, height: 42)
                            .background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.name).font(.headline)
                            Text(summary.version).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(summary.status.rawValue, systemImage: "circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(summary.status == .online ? .green : .secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Utilization") {
                    if let cpu = summary.cpuPercent {
                        MetricRow(title: "CPU", systemImage: "cpu", value: cpu)
                    }
                    if let memory = summary.memoryPercent {
                        MetricRow(
                            title: "Memory",
                            systemImage: "memorychip",
                            value: memory,
                            detail: byteDetail(used: summary.memoryUsed, total: summary.memoryTotal)
                        )
                    }
                    if let disk = summary.diskPercent {
                        NavigationLink {
                            SystemDrivesView(model: model)
                        } label: {
                            MetricRow(
                                title: "Storage · OS drive",
                                systemImage: "internaldrive",
                                value: disk,
                                detail: storageDetail(
                                    used: summary.diskUsed,
                                    free: summary.diskFree,
                                    total: summary.diskTotal
                                )
                            )
                        }
                    }
                    NavigationLink {
                        OtherDrivesView(model: model)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Other drives")
                                Text("Capacity, used, and free space")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "externaldrive")
                        }
                    }
                    if summary.cpuPercent == nil,
                       summary.memoryPercent == nil,
                       summary.diskPercent == nil {
                        Text("Utilization is not available yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Server") {
                    if let model = summary.model, !model.isEmpty {
                        LabeledContent("Model", value: model)
                    }
                    if let architecture = summary.architecture, !architecture.isEmpty {
                        LabeledContent("Architecture", value: architecture)
                    }
                    if let temperature = summary.temperature, temperature > 0 {
                        LabeledContent("CPU temperature", value: temperature.formatted(.number.precision(.fractionLength(0))) + " °C")
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Server Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading server…")
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Dashboard")
        .refreshable { await loadSummary() }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .disabled(isLoading)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await loadSummary()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: refreshInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, scenePhase == .active else { return }
                await loadSummary()
            }
        }
    }

    private func refresh() {
        Task { await loadSummary() }
    }

    private func loadSummary() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            summary = try await client.fetchServerSummary()
            errorMessage = nil
        } catch {
            summary = nil
            errorMessage = error.localizedDescription
        }
    }

    private func byteDetail(used: Int64?, total: Int64?) -> String? {
        guard let used, let total else { return nil }
        return "\(used.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))"
    }

    private func storageDetail(
        used: Int64?,
        free: Int64?,
        total: Int64?
    ) -> String? {
        guard let used, let total else { return nil }
        let resolvedFree = free ?? max(0, total - used)
        return "\(used.formatted(.byteCount(style: .file))) used · \(resolvedFree.formatted(.byteCount(style: .file))) free · \(total.formatted(.byteCount(style: .file))) total"
    }
}

private struct MetricRow: View {
    let title: String
    let systemImage: String
    let value: Double
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(value / 100, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            ProgressView(value: max(0, min(value, 100)), total: 100)
                .tint(value > 90 ? .red : .accentColor)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SystemDrivesView: View {
    @ObservedObject var model: AppModel

    @State private var drives: [StorageDrive] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if !hasLoaded {
                List {
                    ProgressView("Loading OS drive…")
                        .frame(maxWidth: .infinity)
                }
                .navigationTitle("OS Drive")
                .navigationBarTitleDisplayMode(.inline)
            } else if drives.count == 1,
                      let drive = drives.first,
                      drive.devicePaths.count == 1,
                      let devicePath = drive.devicePaths.first {
                SMARTDriveHealthDestination(
                    model: model,
                    devicePath: devicePath,
                    fallbackName: drive.name,
                    fallbackCapacityBytes: drive.totalBytes
                )
            } else if drives.count == 1,
                      let cluster = drives.first,
                      cluster.isRAIDCluster {
                RAIDClusterView(model: model, cluster: cluster)
            } else {
                driveList
            }
        }
        .task {
            guard !hasLoaded else { return }
            await load()
        }
    }

    private var driveList: some View {
        List {
            if drives.isEmpty, let errorMessage {
                ContentUnavailableView {
                    Label("OS Drive Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again", action: refresh)
                }
            } else if drives.isEmpty {
                ContentUnavailableView(
                    "No OS Drive",
                    systemImage: "internaldrive",
                    description: Text("CasaOS did not report the physical drive backing OS storage.")
                )
            } else {
                Section {
                    ForEach(drives) { drive in
                        if drive.devicePaths.isEmpty {
                            DriveUsageRow(drive: drive)
                        } else {
                            NavigationLink {
                                destination(for: drive)
                            } label: {
                                DriveUsageRow(drive: drive)
                            }
                        }
                    }
                } footer: {
                    Text("Storage details are read-only. Open an individual drive to load its SMART health.")
                }
            }
        }
        .navigationTitle("OS Drives")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refresh() {
        Task { await load() }
    }

    @ViewBuilder
    private func destination(for drive: StorageDrive) -> some View {
        if drive.isRAIDCluster {
            RAIDClusterView(model: model, cluster: drive)
        } else if let devicePath = drive.devicePaths.first {
            SMARTDriveHealthDestination(
                model: model,
                devicePath: devicePath,
                fallbackName: drive.name,
                fallbackCapacityBytes: drive.totalBytes
            )
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            drives = try await model.client.fetchSystemDrives()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct OtherDrivesView: View {
    @ObservedObject var model: AppModel

    @State private var drives: [StorageDrive] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var hasLoaded = false

    var body: some View {
        List {
            if !hasLoaded {
                ProgressView("Loading drives…")
                    .frame(maxWidth: .infinity)
            } else if drives.isEmpty, let errorMessage {
                ContentUnavailableView {
                    Label("Drives Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again", action: refresh)
                }
            } else if drives.isEmpty {
                ContentUnavailableView(
                    "No Other Drives",
                    systemImage: "externaldrive",
                    description: Text("No mounted non-system drives were reported by CasaOS.")
                )
            } else {
                Section {
                    ForEach(drives) { drive in
                        if drive.devicePaths.isEmpty {
                            DriveUsageRow(drive: drive)
                        } else {
                            NavigationLink {
                                destination(for: drive)
                            } label: {
                                DriveUsageRow(drive: drive)
                            }
                        }
                    }
                } footer: {
                    Text("Storage details are read-only. Open an individual drive to load its SMART health. Pull to refresh this list.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Other Drives")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            guard !hasLoaded else { return }
            await load()
        }
    }

    private func refresh() {
        Task { await load() }
    }

    @ViewBuilder
    private func destination(for drive: StorageDrive) -> some View {
        if drive.isRAIDCluster {
            RAIDClusterView(model: model, cluster: drive)
        } else if let devicePath = drive.devicePaths.first {
            SMARTDriveHealthDestination(
                model: model,
                devicePath: devicePath,
                fallbackName: drive.name,
                fallbackCapacityBytes: drive.totalBytes
            )
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            drives = try await model.client.fetchStorageDrives()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RAIDClusterView: View {
    @ObservedObject var model: AppModel
    let cluster: StorageDrive

    var body: some View {
        List {
            Section("RAID cluster") {
                DriveUsageRow(drive: cluster, showsTopology: false)
            }

            Section {
                ForEach(Array(cluster.devicePaths.enumerated()), id: \.element) { index, path in
                    NavigationLink {
                        SMARTDriveHealthDestination(
                            model: model,
                            devicePath: path,
                            fallbackName: "Drive \(index + 1)",
                            fallbackCapacityBytes: nil
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Drive \(index + 1)")
                                    .font(.headline)
                                Text(path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            } header: {
                Text("Individual drives")
            } footer: {
                Text("SMART information is loaded only after you open an individual drive.")
            }
        }
        .navigationTitle(cluster.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct SMARTDriveHealthDestination: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hostKeyConfirmation: SMARTDriveHostKeyConfirmationModel

    private let client: any CasaOSClient
    private let controller: any SMARTDriveHealthControlling
    private let devicePath: String
    private let fallbackName: String
    private let fallbackCapacityBytes: Int64?

    init(
        model: AppModel,
        devicePath: String,
        fallbackName: String,
        fallbackCapacityBytes: Int64?
    ) {
        let confirmation = SMARTDriveHostKeyConfirmationModel()
        _hostKeyConfirmation = StateObject(wrappedValue: confirmation)
        client = model.client
        self.devicePath = devicePath
        self.fallbackName = fallbackName
        self.fallbackCapacityBytes = fallbackCapacityBytes

        if model.mockMode {
            controller = MockSMARTDriveHealthController()
        } else {
            controller = SSHSMARTDriveHealthController(
                serverURL: model.serverURL,
                credentialMode: model.sshCredentialMode,
                credentialStore: model.sshCredentialStore,
                hostKeyConfirmation: { [weak confirmation] prompt in
                    guard let confirmation else { return false }
                    return await confirmation.requestApproval(for: prompt)
                }
            )
        }
    }

    var body: some View {
        PhysicalDriveHealthView(
            client: client,
            smartController: controller,
            devicePath: devicePath,
            fallbackName: fallbackName,
            fallbackCapacityBytes: fallbackCapacityBytes
        )
        .alert(
            "Verify SSH Server",
            isPresented: Binding(
                get: { hostKeyConfirmation.prompt != nil },
                set: { if !$0 { hostKeyConfirmation.resolve(accepted: false) } }
            )
        ) {
            Button("Trust and Continue") {
                hostKeyConfirmation.resolve(accepted: true)
            }
            Button("Cancel", role: .cancel) {
                hostKeyConfirmation.resolve(accepted: false)
            }
        } message: {
            if let prompt = hostKeyConfirmation.prompt {
                Text(
                    "Confirm this fingerprint for \(prompt.host.description):\n\n"
                        + prompt.fingerprint
                        + "\n\nOnly trust it if it matches your server."
                )
            }
        }
        .onDisappear {
            hostKeyConfirmation.resolve(accepted: false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            hostKeyConfirmation.resolve(accepted: false)
        }
    }
}

private struct PhysicalDriveHealthView: View {
    @Environment(\.scenePhase) private var scenePhase

    let client: any CasaOSClient
    let smartController: any SMARTDriveHealthControlling
    let devicePath: String
    let fallbackName: String
    let fallbackCapacityBytes: Int64?

    @State private var health: PhysicalDriveHealth?
    @State private var errorMessage: String?
    @State private var lastChecked: Date?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var smartPreflight: SMARTDrivePreflight?
    @State private var smartMetrics: SMARTDriveMetrics?
    @State private var smartErrorMessage: String?
    @State private var smartRemediation: String?
    @State private var smartRetryBlocked = false
    @State private var isSMARTChecking = false
    @State private var didWakeForSMART = false
    @State private var smartLastChecked: Date?
    @State private var showsWakeConfirmation = false
    @State private var smartActionTask: Task<Void, Never>?

    var body: some View {
        List {
            casaOSSMARTContent
            detailedSMARTContent
        }
        .navigationTitle(resolvedName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .toolbar {
            Button("Refresh CasaOS SMART", systemImage: "arrow.clockwise", action: refresh)
                .disabled(isLoading)
        }
        .task {
            guard !hasLoaded else { return }
            await load()
        }
        .alert("Wake \(devicePath)?", isPresented: $showsWakeConfirmation) {
            Button("Wake & Read SMART") {
                startWakeAndRead()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Drive: \(resolvedName)\nDevice: \(devicePath)\n\n"
                    + "This spins up this physical drive and may interrupt its configured sleep period. "
                    + "Only this drive will be checked."
            )
        }
        .onDisappear(perform: cancelSMARTAction)
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            cancelSMARTAction()
        }
    }

    @ViewBuilder
    private var casaOSSMARTContent: some View {
        if let health {
            Section {
                SMARTOverviewCard(health: health)
            }

            Section("Drive information") {
                if let model = health.model {
                    LabeledContent("Model", value: model)
                }
                if let serialNumber = health.serialNumber {
                    LabeledContent("Serial", value: serialNumber)
                }
                if let diskType = health.diskType {
                    LabeledContent("Type", value: diskType)
                }
                if let capacityBytes = health.capacityBytes ?? fallbackCapacityBytes {
                    LabeledContent(
                        "Capacity",
                        value: capacityBytes.formatted(.byteCount(style: .file))
                    )
                }
                LabeledContent("Device") {
                    Text(health.devicePath)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }

            if health.model == nil,
               health.serialNumber == nil,
               health.diskType == nil,
               health.temperatureCelsius == nil {
                Section {
                    Label {
                        Text(limitedSMARTExplanation(for: health))
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Limited SMART data")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } footer: {
                    Text("The last successful CasaOS result is still shown.")
                }
            }

            Section {
                Text("This is CasaOS's reported summary, not an independent diagnosis. CasaOS requests SMART in standby-safe mode and does not wake a sleeping drive. Some CasaOS versions also return a default healthy state when detailed SMART data is unavailable, especially for system or USB-backed devices. This app does not start a SMART self-test.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } footer: {
                if let lastChecked {
                    Text("Updated \(lastChecked.formatted(date: .abbreviated, time: .standard)). CasaOS may serve a cached SMART result. Refresh manually to request it again.")
                }
            }
        } else if hasLoaded, let errorMessage {
            Section {
                ContentUnavailableView {
                    Label("CasaOS SMART Unavailable", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try CasaOS Again", action: refresh)
                }
            }
        } else {
            Section {
                ProgressView("Loading CasaOS SMART health…")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detailedSMARTContent: some View {
        Section {
            if isSMARTChecking {
                ProgressView(didWakeForSMART ? "Reading SMART metrics…" : "Checking without wake…")
            }

            if didWakeForSMART {
                Label(
                    "SMART metrics were read after you confirmed spin-up of \(devicePath).",
                    systemImage: "externaldrive.fill.badge.checkmark"
                )
                .font(.footnote)
            } else if let smartPreflight {
                SMARTPreflightStatus(preflight: smartPreflight)
            }

            if let smartErrorMessage {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(smartErrorMessage)
                        if let smartRemediation {
                            Text(smartRemediation)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }

            if !smartRetryBlocked {
                Button(
                    smartPreflight == nil ? "Check via SSH (Standby-Safe)" : "Check Again (Standby-Safe)",
                    systemImage: "stethoscope",
                    action: startStandbySafeCheck
                )
                .disabled(isSMARTChecking)
            }

            if let smartPreflight,
               smartPreflight.requiresWakeConfirmation,
               smartMetrics == nil {
                Button("Wake & Read SMART", systemImage: "externaldrive.fill.badge.plus") {
                    showsWakeConfirmation = true
                }
                .disabled(isSMARTChecking)
            }
        } header: {
            Text("Detailed SMART via SSH")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Never runs automatically. Standby-safe check tests only \(devicePath) and will not wake it. A separate on-screen confirmation is required before any spin-up read.")
                if let smartLastChecked {
                    Text("Direct SMART checked \(smartLastChecked.formatted(date: .abbreviated, time: .standard)).")
                }
            }
        }

        if let smartMetrics {
            detailedMetricsContent(smartMetrics)
        }
    }

    @ViewBuilder
    private func detailedMetricsContent(_ metrics: SMARTDriveMetrics) -> some View {
        let healthMetrics = smartMetrics(
            metrics,
            kinds: [.percentageUsed, .availableSpare, .ataLife, .criticalWarning]
        )
        let powerMetrics = smartMetrics(
            metrics,
            kinds: [.powerOnHours, .powerCycleCount]
        )
        let errorMetrics = smartMetrics(
            metrics,
            kinds: [
                .reallocatedSectorCount,
                .currentPendingSectorCount,
                .offlineUncorrectableSectorCount,
                .udmaCRCErrorCount,
                .mediaErrors,
            ]
        )
        let usageMetrics = smartMetrics(
            metrics,
            kinds: [.dataUnitsRead, .dataUnitsWritten]
        )

        Section("SMART overview") {
            SMARTDetailedOverviewCard(metrics: metrics)
        }
        if !healthMetrics.isEmpty {
            SMARTMetricSection(title: "Health and life", metrics: healthMetrics)
        }
        if !powerMetrics.isEmpty {
            SMARTMetricSection(title: "Power history", metrics: powerMetrics)
        }
        if !errorMetrics.isEmpty {
            SMARTMetricSection(title: "Errors and reliability", metrics: errorMetrics)
        }
        if !usageMetrics.isEmpty {
            SMARTMetricSection(title: "NVMe usage", metrics: usageMetrics)
        }
        SMARTIdentitySection(metrics: metrics)
    }

    private func refresh() {
        Task { await load() }
    }

    private func startStandbySafeCheck() {
        guard !isSMARTChecking else { return }
        smartActionTask = Task { await runStandbySafeCheck() }
    }

    private func runStandbySafeCheck() async {
        isSMARTChecking = true
        smartErrorMessage = nil
        smartRemediation = nil
        smartRetryBlocked = false
        didWakeForSMART = false
        smartPreflight = nil
        smartMetrics = nil
        defer {
            isSMARTChecking = false
            smartActionTask = nil
        }

        do {
            let result = try await smartController.preflight(devicePath: devicePath)
            guard !Task.isCancelled else { return }
            smartPreflight = result
            smartMetrics = result.metrics
            smartLastChecked = .now
            if result.powerState == .awake, result.metrics == nil {
                smartErrorMessage = "Drive is awake, but smartctl returned no structured metrics."
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            recordSMARTError(error)
        }
    }

    private func startWakeAndRead() {
        guard !isSMARTChecking,
              smartPreflight?.requiresWakeConfirmation == true else { return }
        smartActionTask = Task { await runWakeAndRead() }
    }

    private func runWakeAndRead() async {
        isSMARTChecking = true
        smartErrorMessage = nil
        smartRemediation = nil
        defer {
            isSMARTChecking = false
            smartActionTask = nil
        }

        do {
            let result = try await smartController.wakeAndFetchMetrics(
                devicePath: devicePath,
                confirmation: .userConfirmed
            )
            guard !Task.isCancelled else { return }
            smartMetrics = result
            didWakeForSMART = true
            smartLastChecked = .now
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            recordSMARTError(error)
        }
    }

    private func recordSMARTError(_ error: any Error) {
        smartPreflight = nil
        smartErrorMessage = error.localizedDescription
        smartRetryBlocked = false
        smartRemediation = nil

        guard let smartError = error as? SMARTDriveError else { return }
        switch smartError {
        case .smartctlUnavailable:
            smartRetryBlocked = true
            smartRemediation = "Install smartmontools on the server before leaving and reopening this drive."
        case .deviceTypeRequired:
            smartRetryBlocked = true
            smartRemediation = "This USB bridge needs a verified smartctl device type. Casa Native will not guess one."
        case .missingCredentials:
            smartRemediation = "Save working SSH credentials in Settings, then check again."
        default:
            break
        }
    }

    private func cancelSMARTAction() {
        showsWakeConfirmation = false
        smartActionTask?.cancel()
        smartActionTask = nil
        isSMARTChecking = false
    }

    private func smartMetrics(
        _ metrics: SMARTDriveMetrics,
        kinds: [SMARTDriveMetric.Kind]
    ) -> [SMARTDriveMetric] {
        metrics.metrics.filter { kinds.contains($0.kind) }
    }

    private var resolvedName: String {
        guard let health else { return fallbackName }
        let deviceName = (devicePath as NSString).lastPathComponent
        return health.name == deviceName ? fallbackName : health.name
    }

    private func limitedSMARTExplanation(for health: PhysicalDriveHealth) -> String {
        if health.status == .unavailable {
            return "CasaOS did not expose health or SMART details for this device. CasaOS's standby-safe check does not wake sleeping drives, and CasaOS 0.4.15 commonly omits USB-backed drives from its health endpoint. If another activity wakes the drive, refresh this screen manually."
        }
        return "CasaOS returned only an overall reported status for this device. USB bridges, virtual disks, and devices without SMART passthrough may not expose model, serial, type, or temperature."
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            health = try await client.fetchDriveHealth(devicePath: devicePath)
            lastChecked = .now
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SMARTPreflightStatus: View {
    let preflight: SMARTDrivePreflight

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    private var title: String {
        switch preflight.powerState {
        case .awake: "Drive is awake"
        case .standby: "Drive is sleeping"
        case .unknown: "Power state unavailable"
        }
    }

    private var detail: String {
        if let detail = preflight.detail, !detail.isEmpty {
            return detail
        }
        switch preflight.powerState {
        case .awake:
            return "Metrics were read without issuing a wake command."
        case .standby:
            return "Standby-safe check did not wake or read this drive."
        case .unknown:
            return "Drive was not woken. Confirm spin-up before requesting metrics."
        }
    }

    private var systemImage: String {
        switch preflight.powerState {
        case .awake: "sun.max.fill"
        case .standby: "moon.zzz.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch preflight.powerState {
        case .awake: .green
        case .standby: .indigo
        case .unknown: .orange
        }
    }
}

private struct SMARTDetailedOverviewCard: View {
    let metrics: SMARTDriveMetrics

    var body: some View {
        HStack(spacing: 12) {
            SMARTMetric(
                title: "Overall health",
                value: overallHealthText,
                systemImage: overallHealthImage,
                tint: overallHealthTint
            )
            Divider()
            SMARTMetric(
                title: "Temperature",
                value: temperatureText,
                systemImage: "thermometer.medium",
                tint: temperatureTint
            )
        }
        .padding(.vertical, 8)
    }

    private var overallHealthText: String {
        switch metrics.overallHealthPassed {
        case true: "Passed"
        case false: "Failed"
        case nil: "Unavailable"
        }
    }

    private var overallHealthImage: String {
        switch metrics.overallHealthPassed {
        case true: "checkmark.circle.fill"
        case false: "exclamationmark.triangle.fill"
        case nil: "questionmark.circle.fill"
        }
    }

    private var overallHealthTint: Color {
        switch metrics.overallHealthPassed {
        case true: .green
        case false: .red
        case nil: .gray
        }
    }

    private var temperatureText: String {
        guard let value = metrics.temperatureCelsius else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(0))) + " °C"
    }

    private var temperatureTint: Color {
        guard let value = metrics.temperatureCelsius else { return .gray }
        if value >= 60 { return .red }
        if value >= 50 { return .orange }
        return .blue
    }
}

private struct SMARTMetricSection: View {
    let title: String
    let metrics: [SMARTDriveMetric]

    var body: some View {
        Section(title) {
            ForEach(metrics) { metric in
                SMARTAttributeRow(metric: metric)
            }
        }
    }
}

private struct SMARTAttributeRow: View {
    let metric: SMARTDriveMetric

    var body: some View {
        LabeledContent {
            Text(formattedValue)
                .monospacedDigit()
                .textSelection(.enabled)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.label)
                Text(sourceText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var formattedValue: String {
        guard let unit = metric.unit, !unit.isEmpty else { return metric.value }
        return unit == "%" ? metric.value + unit : metric.value + " " + unit
    }

    private var sourceText: String {
        switch metric.source {
        case let .nvmeHealthLog(field):
            "NVMe · \(field)"
        case let .ataAttribute(id, name):
            "ATA attribute \(id) · \(name)"
        case let .smartctl(field):
            "smartctl · \(field)"
        }
    }
}

private struct SMARTIdentitySection: View {
    let metrics: SMARTDriveMetrics

    var body: some View {
        Section("Drive identity and protocol") {
            if let modelName = metrics.modelName, !modelName.isEmpty {
                LabeledContent("Model", value: modelName)
            }
            if let serialNumber = metrics.serialNumber, !serialNumber.isEmpty {
                LabeledContent("Serial", value: serialNumber)
            }
            if let firmwareVersion = metrics.firmwareVersion, !firmwareVersion.isEmpty {
                LabeledContent("Firmware", value: firmwareVersion)
            }
            if let protocolName = metrics.protocolName, !protocolName.isEmpty {
                LabeledContent("Protocol", value: protocolName)
            }
            if let deviceType = metrics.deviceType, !deviceType.isEmpty {
                LabeledContent("smartctl device type", value: deviceType)
            }
            if let capacityBytes = metrics.capacityBytes {
                LabeledContent(
                    "Capacity",
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: capacityBytes),
                        countStyle: .file
                    )
                )
            }
            LabeledContent("Device") {
                Text(metrics.devicePath)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

private struct SMARTOverviewCard: View {
    let health: PhysicalDriveHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: health.status.systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(health.status.tint)
                    .frame(width: 48, height: 48)
                    .background(health.status.tint.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(health.status.title)
                        .font(.headline)
                    Text(health.status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 12) {
                SMARTMetric(
                    title: "SMART",
                    value: health.status.shortTitle,
                    systemImage: "heart.text.square",
                    tint: health.status.tint
                )
                Divider()
                SMARTMetric(
                    title: "Temperature",
                    value: temperatureText,
                    systemImage: "thermometer.medium",
                    tint: temperatureTint
                )
            }
        }
        .padding(.vertical, 8)
    }

    private var temperatureText: String {
        guard let value = health.temperatureCelsius else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(0))) + " °C"
    }

    private var temperatureTint: Color {
        guard let value = health.temperatureCelsius else { return .gray }
        if value >= 60 { return .red }
        if value >= 50 { return .orange }
        return .blue
    }
}

private struct SMARTMetric: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension PhysicalDriveHealth.Status {
    var title: String {
        switch self {
        case .reportedHealthy: "Reported healthy"
        case .attentionRequired: "Attention required"
        case .unavailable: "SMART unavailable"
        }
    }

    var shortTitle: String {
        switch self {
        case .reportedHealthy: "Reported healthy"
        case .attentionRequired: "Attention"
        case .unavailable: "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .reportedHealthy:
            "CasaOS returned a healthy overall status for this device."
        case .attentionRequired:
            "CasaOS reports that this drive did not pass its SMART status check."
        case .unavailable:
            "CasaOS did not provide an overall SMART result for this device."
        }
    }

    var systemImage: String {
        switch self {
        case .reportedHealthy: "checkmark.circle.fill"
        case .attentionRequired: "exclamationmark.triangle.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .reportedHealthy: .green
        case .attentionRequired: .red
        case .unavailable: .gray
        }
    }
}

private struct DriveUsageRow: View {
    let drive: StorageDrive
    var showsTopology = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name)
                        .font(.headline)
                    if showsTopology, drive.isRAIDCluster {
                        Text("RAID cluster · \(drive.devicePaths.count) drives")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if showsTopology, let devicePath = drive.devicePaths.first {
                        Text(devicePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let percent = drive.usedPercent {
                HStack {
                    Text("Usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        percent / 100,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                }
                ProgressView(value: max(0, min(percent, 100)), total: 100)
                    .tint(percent > 90 ? .red : .accentColor)
                    .accessibilityLabel("Storage used")
                    .accessibilityValue(Text(
                        percent / 100,
                        format: .percent.precision(.fractionLength(0))
                    ))
            }

            HStack(alignment: .top, spacing: 8) {
                StorageValue(
                    title: "Capacity",
                    bytes: drive.totalBytes,
                    alignment: .leading
                )
                StorageValue(
                    title: "Used",
                    bytes: drive.usedBytes,
                    alignment: .center
                )
                StorageValue(
                    title: "Free",
                    bytes: drive.freeBytes,
                    alignment: .trailing
                )
            }

            Text(drive.mountPoints.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
    }
}

private struct StorageValue: View {
    let title: String
    let bytes: Int64?
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(bytes?.formatted(.byteCount(style: .file)) ?? "—")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }
}

@MainActor
private final class SMARTDriveHostKeyConfirmationModel:
    ObservableObject,
    @unchecked Sendable
{
    @Published private(set) var prompt: SSHHostKeyPrompt?
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestApproval(for prompt: SSHHostKeyPrompt) async -> Bool {
        resolve(accepted: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.prompt = prompt
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(accepted: false)
            }
        }
    }

    func resolve(accepted: Bool) {
        prompt = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: accepted)
    }
}
