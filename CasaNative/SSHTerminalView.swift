import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH
import SwiftTerm
import SwiftUI
import UIKit

enum SSHConnectionError: LocalizedError, Equatable, Sendable {
    case invalidTarget
    case missingCredentials
    case sharedCredentialsUnavailable
    case passwordAuthenticationUnavailable
    case invalidChannelType
    case channelFailure
    case sessionEnded

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            "The CasaOS address cannot be used as an SSH host."
        case .missingCredentials:
            "No SSH credentials are saved for this server."
        case .sharedCredentialsUnavailable:
            "Your restored CasaOS session does not include the password SSH needs. Re-authenticate for SSH in Settings, then try again."
        case .passwordAuthenticationUnavailable:
            "The SSH server did not accept password authentication."
        case .invalidChannelType:
            "The SSH server opened an unexpected channel type."
        case .channelFailure:
            "The SSH server rejected the terminal request."
        case .sessionEnded:
            "The SSH session ended."
        }
    }
}

@MainActor
struct SSHTerminalView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: SSHTerminalSession
    @State private var isConfirmingHostKeyReset = false

    init(
        serverURL: URL,
        credentialMode: SSHCredentialMode,
        credentialStore: any SSHCredentialStoring,
        hostKeyStore: any SSHPinnedHostKeyStoring = SSHHostKeyStore(),
        port: Int = 22,
        defaultUsername: String = ""
    ) {
        _session = StateObject(
            wrappedValue: SSHTerminalSession(
                serverURL: serverURL,
                credentialMode: credentialMode,
                credentialStore: credentialStore,
                hostKeyStore: hostKeyStore,
                port: port,
                defaultUsername: defaultUsername
            )
        )
    }

    var body: some View {
        Group {
            switch session.phase {
            case .loadingCredentials:
                ProgressView("Loading SSH sign-in…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .needsCredentials:
                if session.credentialMode == .separate {
                    credentialsForm
                } else {
                    credentialsUnavailableView(
                        message: SSHConnectionError
                            .sharedCredentialsUnavailable
                            .localizedDescription
                    )
                }

            case let .credentialsUnavailable(message):
                credentialsUnavailableView(message: message)

            case .ready, .connecting, .connected:
                terminalSurface

            case let .failed(message):
                failureView(message: message)

            case let .ended(message):
                endedView(message: message)
            }
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.prepare() }
        .onDisappear {
            session.destroy(reason: "Terminal closed. Start a new session to reconnect.")
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            session.destroy(reason: "Session ended when Casa Native left focus.")
        }
        .alert(
            "Verify SSH Server",
            isPresented: Binding(
                get: { session.pendingHostKey != nil },
                set: { if !$0 { session.rejectHostKey() } }
            )
        ) {
            Button("Trust and Connect") { session.acceptHostKey() }
            Button("Cancel", role: .cancel) { session.rejectHostKey() }
        } message: {
            if let prompt = session.pendingHostKey {
                Text(
                    "Confirm this fingerprint for \(prompt.host.description):\n\n"
                        + prompt.fingerprint
                        + "\n\nOnly trust it if it matches your server."
                )
            }
        }
        .confirmationDialog(
            "Forget the saved SSH server identity?",
            isPresented: $isConfirmingHostKeyReset,
            titleVisibility: .visible
        ) {
            Button("Forget and Verify Again", role: .destructive) {
                Task { await session.forgetSavedHostKeyAndRetry() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Only continue if you intentionally replaced or reinstalled the SSH server. "
                    + "The next connection will show its new fingerprint for approval."
            )
        }
    }

    private var credentialsForm: some View {
        Form {
            Section {
                TextField("Username", text: $session.draftUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)

                SecureField("Password", text: $session.draftPassword)
                    .textContentType(.password)
                    .onSubmit(saveCredentials)
            } header: {
                Text(session.credentialMode.title)
            } footer: {
                Text(credentialFooter)
            }

            Section {
                Button(action: saveCredentials) {
                    if session.isSavingCredentials {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Save and Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    session.isSavingCredentials
                        || session.draftUsername
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                        || session.draftPassword.isEmpty
                )

                if let error = session.credentialError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var credentialFooter: String {
        switch session.credentialMode {
        case .casaOS:
            "Casa Native can reuse this sign-in for CasaOS and SSH. "
                + "Your Linux SSH account must use the same username and password. "
                + "The sign-in is stored only in this iPhone’s Keychain."
        case .separate:
            "These SSH credentials are kept separate from CasaOS and stored only "
                + "in this iPhone’s Keychain."
        }
    }

    private var terminalSurface: some View {
        ZStack {
            SSHEmbeddedTerminal(session: session)
                .background(Color.black)

            if session.phase != .connected {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Opening secure SSH session…")
                        .foregroundStyle(.white)
                }
                .padding(20)
                .background(.black.opacity(0.72), in: .rect(cornerRadius: 14))
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func failureView(message: String) -> some View {
        ContentUnavailableView {
            Label("SSH Connection Failed", systemImage: "terminal")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { session.retry() }
                .buttonStyle(.borderedProminent)
            if session.credentialMode == .separate {
                Button("Edit Credentials") { session.requestCredentialEntry() }
                    .buttonStyle(.bordered)
            }
            if session.hostKeyMismatch != nil {
                Button("Review Changed Server Key", role: .destructive) {
                    isConfirmingHostKeyReset = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func credentialsUnavailableView(message: String) -> some View {
        ContentUnavailableView {
            Label("CasaOS Sign-In Required", systemImage: "key.fill")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { session.retry() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func endedView(message: String) -> some View {
        ContentUnavailableView {
            Label("SSH Session Ended", systemImage: "terminal")
        } description: {
            Text(message)
        } actions: {
            Button("Start New Session") { session.retry() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func saveCredentials() {
        Task { await session.saveDraftCredentials() }
    }
}

@MainActor
private struct SSHEmbeddedTerminal: UIViewRepresentable {
    let session: SSHTerminalSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> TerminalView {
        let options = TerminalOptions(
            termName: "xterm-256color",
            scrollback: 500,
            enableSixelReported: false,
            kittyImageCacheLimitBytes: 8 * 1_024 * 1_024,
            maximumBidiParagraphRows: 100
        )
        let view = TerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            options: options
        )
        view.backgroundColor = .black
        view.terminalDelegate = context.coordinator
        view.linkReporting = .none
        session.attachTerminal(view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(
        _ uiView: TerminalView,
        coordinator: Coordinator
    ) {
        uiView.terminalDelegate = nil
        coordinator.session.detachTerminal(uiView)
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        let session: SSHTerminalSession

        init(session: SSHTerminalSession) {
            self.session = session
        }

        func sizeChanged(
            source: TerminalView,
            newCols: Int,
            newRows: Int
        ) {
            session.resize(columns: newCols, rows: newRows)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(data)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(
            source: TerminalView,
            link: String,
            params: [String: String]
        ) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private enum SSHPTYOutput: Sendable {
    case stdout(ByteBuffer)
    case stderr(ByteBuffer)
}

private enum SSHExecOutput: Sendable {
    case stdout(ByteBuffer)
    case stderr(ByteBuffer)
    case exitStatus(Int)
}

private struct TTYStdinWriter: @unchecked Sendable {
    let channel: Channel

    func write(_ buffer: ByteBuffer) async throws {
        try await channel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        )
    }

    func changeSize(
        cols: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws {
        try await channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: pixelWidth,
                terminalPixelHeight: pixelHeight
            )
        )
    }
}

private final class SSHPasswordAuthenticationDelegate:
    NIOSSHClientUserAuthenticationDelegate,
    @unchecked Sendable
{
    private var credentials: SSHCredentials?

    init(credentials: SSHCredentials) {
        self.credentials = credentials
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard
            availableMethods.contains(.password),
            let credentials
        else {
            self.credentials = nil
            nextChallengePromise.fail(
                SSHConnectionError.passwordAuthenticationUnavailable
            )
            return
        }

        // A password is offered once, then released from this delegate immediately.
        self.credentials = nil
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: credentials.username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: credentials.password))
            )
        )
    }
}

private final class SSHParentErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private let resources: SSHConnectionResources

    init(resources: SSHConnectionResources) {
        self.resources = resources
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        resources.record(error, from: context.channel)
        context.close(promise: nil)
    }
}

private final class SSHPTYOutputHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = SSHChannelData

    private let continuation:
        AsyncThrowingStream<SSHPTYOutput, any Error>.Continuation
    private let resources: SSHConnectionResources
    private var pendingResponse: EventLoopPromise<Void>?

    init(
        continuation:
            AsyncThrowingStream<SSHPTYOutput, any Error>.Continuation,
        resources: SSHConnectionResources
    ) {
        self.continuation = continuation
        self.resources = resources
    }

    func request<Event: Sendable>(
        _ event: Event,
        on channel: Channel
    ) -> EventLoopFuture<Void> {
        precondition(channel.eventLoop.inEventLoop)
        guard pendingResponse == nil else {
            return channel.eventLoop.makeFailedFuture(
                SSHConnectionError.channelFailure
            )
        }

        let response = channel.eventLoop.makePromise(of: Void.self)
        pendingResponse = response
        let write = channel.eventLoop.makePromise(of: Void.self)
        channel.pipeline.triggerUserOutboundEvent(event, promise: write)
        write.futureResult.whenFailure { [weak self] error in
            self?.failPendingResponse(error)
        }
        return response.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = channelData.data else {
            continuation.finish(throwing: SSHConnectionError.channelFailure)
            context.close(promise: nil)
            return
        }

        switch channelData.type {
        case .channel:
            continuation.yield(.stdout(buffer))
        case .stdErr:
            continuation.yield(.stderr(buffer))
        default:
            break
        }
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        switch event {
        case is ChannelSuccessEvent:
            let response = pendingResponse
            pendingResponse = nil
            response?.succeed(())
        case is ChannelFailureEvent:
            failPendingResponse(SSHConnectionError.channelFailure)
            continuation.finish(throwing: SSHConnectionError.channelFailure)
            context.close(promise: nil)
        case is SSHChannelRequestEvent.ExitStatus, ChannelEvent.inputClosed:
            continuation.finish()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failPendingResponse(error)
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let failure = resources.recordedFailure() {
            failPendingResponse(failure)
            continuation.finish(throwing: failure)
        } else {
            failPendingResponse(SSHConnectionError.sessionEnded)
            continuation.finish()
        }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if let failure = resources.recordedFailure() {
            failPendingResponse(failure)
            continuation.finish(throwing: failure)
        } else {
            failPendingResponse(SSHConnectionError.sessionEnded)
            continuation.finish()
        }
    }

    private func failPendingResponse(_ error: any Error) {
        let response = pendingResponse
        pendingResponse = nil
        response?.fail(error)
    }
}

private final class SSHExecOutputHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = SSHChannelData

    private let continuation:
        AsyncThrowingStream<SSHExecOutput, any Error>.Continuation
    private let resources: SSHConnectionResources
    private let maximumOutputBytes: Int
    private var receivedOutputBytes = 0
    private var pendingResponse: EventLoopPromise<Void>?
    private var didFinish = false
    private var exitStatus: Int?
    private var receivedInputClosed = false

    init(
        continuation:
            AsyncThrowingStream<SSHExecOutput, any Error>.Continuation,
        resources: SSHConnectionResources,
        maximumOutputBytes: Int
    ) {
        self.continuation = continuation
        self.resources = resources
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }

    func request(
        _ event: SSHChannelRequestEvent.ExecRequest,
        on channel: Channel
    ) -> EventLoopFuture<Void> {
        precondition(channel.eventLoop.inEventLoop)
        guard pendingResponse == nil, !didFinish else {
            return channel.eventLoop.makeFailedFuture(
                SSHConnectionError.channelFailure
            )
        }

        let response = channel.eventLoop.makePromise(of: Void.self)
        pendingResponse = response
        let write = channel.eventLoop.makePromise(of: Void.self)
        channel.pipeline.triggerUserOutboundEvent(event, promise: write)
        write.futureResult.whenFailure { [weak self] error in
            self?.finish(throwing: error)
        }
        return response.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !didFinish else { return }
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = channelData.data else {
            finish(throwing: SSHConnectionError.channelFailure)
            resources.close()
            return
        }

        let (nextCount, overflow) = receivedOutputBytes.addingReportingOverflow(
            buffer.readableBytes
        )
        guard !overflow, nextCount <= maximumOutputBytes else {
            finish(throwing: PWMFanError.outputLimitExceeded)
            resources.close()
            return
        }
        receivedOutputBytes = nextCount

        switch channelData.type {
        case .channel:
            continuation.yield(.stdout(buffer))
        case .stdErr:
            continuation.yield(.stderr(buffer))
        default:
            break
        }
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        switch event {
        case is ChannelSuccessEvent:
            let response = pendingResponse
            pendingResponse = nil
            response?.succeed(())
        case is ChannelFailureEvent:
            finish(throwing: SSHConnectionError.channelFailure)
            resources.close()
        case let status as SSHChannelRequestEvent.ExitStatus:
            guard !didFinish, exitStatus == nil else { return }
            exitStatus = status.exitStatus
            finishNormallyIfComplete()
        case ChannelEvent.inputClosed:
            receivedInputClosed = true
            finishNormallyIfComplete()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        finish(throwing: error)
        resources.close()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !didFinish {
            if let exitStatus {
                finishNormally(exitStatus: exitStatus)
            } else {
                finish(
                    throwing: resources.recordedFailure()
                        ?? SSHConnectionError.sessionEnded
                )
            }
        }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        guard !didFinish else { return }
        if let exitStatus {
            finishNormally(exitStatus: exitStatus)
        } else {
            finish(
                throwing: resources.recordedFailure()
                    ?? SSHConnectionError.sessionEnded
            )
        }
    }

    private func finishNormallyIfComplete() {
        guard receivedInputClosed, let exitStatus else { return }
        finishNormally(exitStatus: exitStatus)
    }

    private func finishNormally(exitStatus: Int) {
        guard !didFinish else { return }
        didFinish = true
        let response = pendingResponse
        pendingResponse = nil
        response?.succeed(())
        continuation.yield(.exitStatus(exitStatus))
        continuation.finish()
    }

    private func finish(throwing error: any Error) {
        guard !didFinish else { return }
        didFinish = true
        let response = pendingResponse
        pendingResponse = nil
        response?.fail(error)
        continuation.finish(throwing: error)
    }
}

private final class SSHConnectionResources: @unchecked Sendable {
    private let lock = NSLock()
    private var parentChannel: Channel?
    private var childChannel: Channel?
    private var isClosed = false
    private var failure: (any Error)?
    private var pendingFailures: [ObjectIdentifier: any Error] = [:]

    func installParent(_ channel: Channel) -> Bool {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            channel.close(promise: nil)
            return false
        }
        parentChannel = channel
        failure = pendingFailures[ObjectIdentifier(channel)]
        pendingFailures.removeAll(keepingCapacity: false)
        lock.unlock()
        return true
    }

    func installChild(_ channel: Channel) -> Bool {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            channel.close(promise: nil)
            return false
        }
        childChannel = channel
        lock.unlock()
        return true
    }

    func record(_ error: any Error, from channel: Channel) {
        lock.lock()
        if let parentChannel {
            if parentChannel === channel, failure == nil {
                failure = error
            }
        } else {
            let id = ObjectIdentifier(channel)
            if pendingFailures[id] == nil {
                pendingFailures[id] = error
            }
        }
        lock.unlock()
    }

    func recordedFailure() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let child = childChannel
        let parent = parentChannel
        childChannel = nil
        parentChannel = nil
        lock.unlock()

        child?.close(promise: nil)
        parent?.close(promise: nil)
    }
}

final class SSHClient: @unchecked Sendable {
    private let parentChannel: Channel
    private let resources: SSHConnectionResources

    private init(
        parentChannel: Channel,
        resources: SSHConnectionResources
    ) {
        self.parentChannel = parentChannel
        self.resources = resources
    }

    static func connect(
        host: String,
        port: Int,
        credentials: SSHCredentials,
        serverAuthDelegate: SSHHostKeyPinningDelegate,
        connectTimeout: TimeAmount
    ) async throws -> SSHClient {
        let resources = SSHConnectionResources()
        let bootstrap = ClientBootstrap(
            group: MultiThreadedEventLoopGroup.singleton
        )
        .connectTimeout(connectTimeout)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let authenticationDelegate =
                    SSHPasswordAuthenticationDelegate(
                        credentials: credentials
                    )
                let sshHandler = NIOSSHHandler(
                    role: .client(
                        SSHClientConfiguration(
                            userAuthDelegate: authenticationDelegate,
                            serverAuthDelegate: serverAuthDelegate
                        )
                    ),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                let pipeline = channel.pipeline.syncOperations
                try pipeline.addHandler(sshHandler)
                try pipeline.addHandler(
                    SSHParentErrorHandler(resources: resources)
                )
            }
        }
        .channelOption(
            ChannelOptions.socket(
                SocketOptionLevel(SOL_SOCKET),
                SO_REUSEADDR
            ),
            value: 1
        )
        .channelOption(
            ChannelOptions.socket(
                SocketOptionLevel(IPPROTO_TCP),
                TCP_NODELAY
            ),
            value: 1
        )

        return try await withTaskCancellationHandler {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            guard resources.installParent(channel) else {
                throw CancellationError()
            }
            return SSHClient(parentChannel: channel, resources: resources)
        } onCancel: {
            resources.close()
        }
    }

    fileprivate func withPTY(
        _ request: SSHChannelRequestEvent.PseudoTerminalRequest,
        perform: @escaping @Sendable (
            AsyncThrowingStream<SSHPTYOutput, any Error>,
            TTYStdinWriter
        ) async throws -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await runPTY(request, perform: perform)
        } onCancel: {
            resources.close()
        }
    }

    func execute(_ request: SSHCommandRequest) async throws -> SSHCommandResult {
        try await withTaskCancellationHandler {
            try await runExec(request)
        } onCancel: {
            resources.close()
        }
    }

    private func runExec(
        _ request: SSHCommandRequest
    ) async throws -> SSHCommandResult {
        let (output, continuation) = AsyncThrowingStream<
            SSHExecOutput,
            any Error
        >.makeStream()
        let outputHandler = SSHExecOutputHandler(
            continuation: continuation,
            resources: resources,
            maximumOutputBytes: request.maximumOutputBytes
        )

        let childChannel: Channel
        do {
            childChannel = try await parentChannel.pipeline.handler(
                type: NIOSSHHandler.self
            ).flatMap { sshHandler in
                let promise = self.parentChannel.eventLoop.makePromise(
                    of: Channel.self
                )
                sshHandler.createChannel(
                    promise,
                    channelType: .session
                ) { channel, channelType in
                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(
                            SSHConnectionError.invalidChannelType
                        )
                    }
                    return channel.setOption(
                        ChannelOptions.allowRemoteHalfClosure,
                        value: true
                    ).flatMap {
                        channel.pipeline.addHandler(outputHandler)
                    }
                }
                return promise.futureResult
            }.get()
        } catch {
            throw resources.recordedFailure() ?? error
        }

        guard resources.installChild(childChannel) else {
            continuation.finish(throwing: CancellationError())
            throw CancellationError()
        }

        // Creating the SSH session channel is the first operation that waits
        // for server authentication (including any explicit host-key prompt).
        // Start the short command deadline only after that user-controlled
        // trust decision and authentication have completed.
        return try await withThrowingTaskGroup(
            of: SSHCommandResult.self
        ) { group in
            group.addTask {
                try await self.runPreparedExec(
                    request,
                    childChannel: childChannel,
                    outputHandler: outputHandler,
                    output: output
                )
            }
            group.addTask {
                try await Task.sleep(
                    for: .seconds(request.timeoutSeconds)
                )
                throw PWMFanError.commandTimedOut
            }

            defer { group.cancelAll() }
            do {
                guard let result = try await group.next() else {
                    throw PWMFanError.invalidCommandResponse
                }
                return result
            } catch {
                self.resources.close()
                throw error
            }
        }
    }

    private func runPreparedExec(
        _ request: SSHCommandRequest,
        childChannel: Channel,
        outputHandler: SSHExecOutputHandler,
        output: AsyncThrowingStream<SSHExecOutput, any Error>
    ) async throws -> SSHCommandResult {
        do {
            try await childChannel.eventLoop.flatSubmit {
                outputHandler.request(
                    SSHChannelRequestEvent.ExecRequest(
                        command: request.command,
                        wantReply: true
                    ),
                    on: childChannel
                )
            }.get()

            if !request.standardInput.isEmpty {
                var buffer = childChannel.allocator.buffer(
                    capacity: request.standardInput.count
                )
                buffer.writeBytes(request.standardInput)
                try await childChannel.writeAndFlush(
                    SSHChannelData(
                        type: .channel,
                        data: .byteBuffer(buffer)
                    )
                ).get()
            }
            try await childChannel.close(mode: .output).get()
        } catch {
            resources.close()
            throw resources.recordedFailure() ?? error
        }

        var standardOutput = Data()
        var standardError = Data()
        do {
            for try await event in output {
                switch event {
                case let .stdout(buffer):
                    standardOutput.append(contentsOf: buffer.readableBytesView)
                case let .stderr(buffer):
                    standardError.append(contentsOf: buffer.readableBytesView)
                case let .exitStatus(status):
                    return SSHCommandResult(
                        standardOutput: standardOutput,
                        standardError: standardError,
                        exitStatus: status
                    )
                }
            }
        } catch {
            throw resources.recordedFailure() ?? error
        }
        throw resources.recordedFailure() ?? SSHConnectionError.sessionEnded
    }

    private func runPTY(
        _ request: SSHChannelRequestEvent.PseudoTerminalRequest,
        perform: @escaping @Sendable (
            AsyncThrowingStream<SSHPTYOutput, any Error>,
            TTYStdinWriter
        ) async throws -> Void
    ) async throws {
        let (output, continuation) = AsyncThrowingStream<
            SSHPTYOutput,
            any Error
        >.makeStream()
        let outputHandler = SSHPTYOutputHandler(
            continuation: continuation,
            resources: resources
        )

        let childChannel: Channel
        do {
            childChannel = try await parentChannel.pipeline.handler(
                type: NIOSSHHandler.self
            ).flatMap { sshHandler in
                let promise = self.parentChannel.eventLoop.makePromise(
                    of: Channel.self
                )
                sshHandler.createChannel(
                    promise,
                    channelType: .session
                ) { channel, channelType in
                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(
                            SSHConnectionError.invalidChannelType
                        )
                    }
                    return channel.setOption(
                        ChannelOptions.allowRemoteHalfClosure,
                        value: true
                    ).flatMap {
                        channel.pipeline.addHandler(outputHandler)
                    }
                }
                return promise.futureResult
            }.get()
        } catch {
            throw resources.recordedFailure() ?? error
        }

        guard resources.installChild(childChannel) else {
            continuation.finish(throwing: CancellationError())
            throw CancellationError()
        }

        do {
            try await childChannel.eventLoop.flatSubmit {
                outputHandler.request(request, on: childChannel)
            }.get()
            try await childChannel.eventLoop.flatSubmit {
                outputHandler.request(
                    SSHChannelRequestEvent.ShellRequest(wantReply: true),
                    on: childChannel
                )
            }.get()
        } catch {
            continuation.finish(throwing: error)
            resources.close()
            throw error
        }

        do {
            try await perform(output, TTYStdinWriter(channel: childChannel))
            resources.close()
        } catch {
            resources.close()
            throw error
        }
    }

    func close() async throws {
        resources.close()
    }

    deinit {
        resources.close()
    }
}

private actor SSHPTYInput {
    private var writer: TTYStdinWriter?
    private var connectionID: UUID?

    func install(_ writer: TTYStdinWriter, connectionID: UUID) {
        self.writer = writer
        self.connectionID = connectionID
    }

    func clear(connectionID: UUID) {
        guard self.connectionID == connectionID else { return }
        writer = nil
        self.connectionID = nil
    }

    func send(_ bytes: [UInt8], connectionID: UUID) async throws {
        guard self.connectionID == connectionID, let writer else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await writer.write(buffer)
    }

    func resize(
        columns: Int,
        rows: Int,
        connectionID: UUID
    ) async throws {
        guard
            self.connectionID == connectionID,
            let writer,
            columns > 0,
            rows > 0
        else { return }
        try await writer.changeSize(
            cols: columns,
            rows: rows,
            pixelWidth: 0,
            pixelHeight: 0
        )
    }
}

@MainActor
final class SSHTerminalSession: ObservableObject {
    enum Phase: Equatable {
        case loadingCredentials
        case needsCredentials
        case credentialsUnavailable(String)
        case ready
        case connecting
        case connected
        case failed(String)
        case ended(String)
    }

    @Published private(set) var phase: Phase = .loadingCredentials
    @Published private(set) var pendingHostKey: SSHHostKeyPrompt?
    @Published private(set) var hostKeyMismatch: SSHHostKeyChangedError?
    @Published var draftUsername: String
    @Published var draftPassword = ""
    @Published private(set) var credentialError: String?
    @Published private(set) var isSavingCredentials = false

    let credentialMode: SSHCredentialMode

    private let serverURL: URL
    private let host: SSHHostIdentity?
    private let credentialStore: any SSHCredentialStoring
    private let hostKeyStore: any SSHPinnedHostKeyStoring
    private let input = SSHPTYInput()

    private var credentials: SSHCredentials?
    private weak var terminalView: TerminalView?
    private var client: SSHClient?
    private var connectionTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?

    init(
        serverURL: URL,
        credentialMode: SSHCredentialMode,
        credentialStore: any SSHCredentialStoring,
        hostKeyStore: any SSHPinnedHostKeyStoring,
        port: Int,
        defaultUsername: String
    ) {
        self.serverURL = serverURL
        self.credentialMode = credentialMode
        self.credentialStore = credentialStore
        self.hostKeyStore = hostKeyStore
        host = try? SSHHostIdentity(serverURL: serverURL, port: port)
        draftUsername = defaultUsername
    }

    func prepare() async {
        guard phase == .loadingCredentials else { return }
        credentials = nil
        draftPassword = ""
        guard host != nil else {
            phase = .failed(SSHConnectionError.invalidTarget.localizedDescription)
            return
        }

        do {
            if let saved = try await credentialStore.load(
                mode: credentialMode,
                for: serverURL
            ) {
                credentials = saved
                draftUsername = saved.username
                phase = .ready
            } else if credentialMode == .casaOS {
                phase = .credentialsUnavailable(
                    SSHConnectionError.sharedCredentialsUnavailable
                        .localizedDescription
                )
            } else {
                phase = .needsCredentials
            }
        } catch {
            credentialError = error.localizedDescription
            phase = credentialMode == .casaOS
                ? .credentialsUnavailable(error.localizedDescription)
                : .needsCredentials
        }
    }

    func saveDraftCredentials() async {
        guard credentialMode == .separate else {
            draftPassword = ""
            credentialError = nil
            phase = .credentialsUnavailable(
                SSHConnectionError.sharedCredentialsUnavailable
                    .localizedDescription
            )
            return
        }

        let username = draftUsername
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = SSHCredentials(
            username: username,
            password: draftPassword
        )
        guard candidate.isComplete else {
            credentialError = SSHCredentialStoreError
                .incompleteCredentials
                .localizedDescription
            return
        }

        isSavingCredentials = true
        defer { isSavingCredentials = false }
        do {
            try await credentialStore.storeSeparate(candidate, for: serverURL)
            credentials = candidate
            draftPassword = ""
            credentialError = nil
            phase = .ready
            connectIfReady()
        } catch {
            credentialError = error.localizedDescription
        }
    }

    func attachTerminal(_ view: TerminalView) {
        terminalView = view
        connectIfReady()
    }

    func detachTerminal(_ view: TerminalView) {
        guard terminalView === view else { return }
        clearTerminal(view)
        terminalView = nil
    }

    func send(_ data: ArraySlice<UInt8>) {
        guard phase == .connected else { return }
        let bytes = Array(data)
        let id = connectionID
        Task { [input] in
            try? await input.send(bytes, connectionID: id)
        }
    }

    func resize(columns: Int, rows: Int) {
        guard phase == .connected else { return }
        let id = connectionID
        Task { [input] in
            try? await input.resize(
                columns: columns,
                rows: rows,
                connectionID: id
            )
        }
    }

    func acceptHostKey() {
        completeHostKeyConfirmation(accepted: true)
    }

    func rejectHostKey() {
        completeHostKeyConfirmation(accepted: false)
    }

    func retry() {
        closeCurrentConnection()
        phase = .loadingCredentials
        hostKeyMismatch = nil
        credentialError = nil
        Task { await prepare() }
    }

    func requestCredentialEntry() {
        closeCurrentConnection()
        guard credentialMode == .separate else {
            credentials = nil
            draftPassword = ""
            credentialError = nil
            hostKeyMismatch = nil
            phase = .credentialsUnavailable(
                SSHConnectionError.sharedCredentialsUnavailable
                    .localizedDescription
            )
            return
        }
        draftUsername = credentials?.username ?? draftUsername
        draftPassword = ""
        credentials = nil
        credentialError = nil
        hostKeyMismatch = nil
        phase = .needsCredentials
    }

    func forgetSavedHostKeyAndRetry() async {
        guard let host else { return }
        do {
            try await hostKeyStore.delete(for: host)
            retry()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func destroy(reason: String) {
        guard phase != .ended(reason) else { return }
        closeCurrentConnection()
        credentials = nil
        draftPassword = ""
        credentialError = nil
        hostKeyMismatch = nil
        if let terminalView {
            clearTerminal(terminalView)
        }
        terminalView = nil
        phase = .ended(reason)
    }

    private func connectIfReady() {
        guard
            phase == .ready,
            terminalView != nil,
            connectionTask == nil,
            let host,
            credentials != nil
        else { return }

        let id = UUID()
        connectionID = id
        phase = .connecting

        let validator = SSHHostKeyPinningDelegate(
            host: host,
            store: hostKeyStore
        ) { [weak self] prompt in
            guard let self else { return false }
            return await self.confirmHostKey(prompt, connectionID: id)
        }
        connectionTask = Task { [weak self] in
            await self?.runConnection(
                host: host,
                hostKeyValidator: validator,
                connectionID: id
            )
        }
    }

    private func runConnection(
        host: SSHHostIdentity,
        hostKeyValidator: SSHHostKeyPinningDelegate,
        connectionID id: UUID
    ) async {
        do {
            let connectedClient = try await openClient(
                host: host,
                hostKeyValidator: hostKeyValidator,
                connectionID: id
            )
            guard connectionID == id, !Task.isCancelled else {
                try? await connectedClient.close()
                return
            }
            client = connectedClient

            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: max(terminalView?.getTerminal().cols ?? 80, 1),
                terminalRowHeight: max(terminalView?.getTerminal().rows ?? 24, 1),
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: .init([.ECHO: 1])
            )

            try await connectedClient.withPTY(request) { @Sendable [weak self] output, writer in
                guard let self else { return }
                await self.didOpenPTY(writer, connectionID: id)

                for try await event in output {
                    if Task.isCancelled { break }
                    switch event {
                    case .stdout(var buffer), .stderr(var buffer):
                        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                        await self.receive(bytes, connectionID: id)
                    }
                }
            }

            guard connectionID == id else { return }
            finishConnection(
                id: id,
                phase: .ended("Remote SSH session closed.")
            )
        } catch {
            guard connectionID == id, !Task.isCancelled else { return }
            if let mismatch = error as? SSHHostKeyChangedError {
                hostKeyMismatch = mismatch
            }
            finishConnection(
                id: id,
                phase: .failed(error.localizedDescription)
            )
        }
    }

    private func openClient(
        host: SSHHostIdentity,
        hostKeyValidator: SSHHostKeyPinningDelegate,
        connectionID id: UUID
    ) async throws -> SSHClient {
        guard connectionID == id, let credentials else {
            throw SSHConnectionError.missingCredentials
        }
        self.credentials = nil

        return try await SSHClient.connect(
            host: host.hostname,
            port: host.port,
            credentials: credentials,
            serverAuthDelegate: hostKeyValidator,
            connectTimeout: .seconds(10)
        )
    }

    private func didOpenPTY(
        _ writer: TTYStdinWriter,
        connectionID id: UUID
    ) async {
        guard connectionID == id else { return }
        await input.install(writer, connectionID: id)
        phase = .connected
        _ = terminalView?.becomeFirstResponder()
    }

    private func receive(_ bytes: [UInt8], connectionID id: UUID) {
        guard connectionID == id, phase == .connected, !bytes.isEmpty else {
            return
        }
        terminalView?.feed(byteArray: bytes[...])
    }

    private func confirmHostKey(
        _ prompt: SSHHostKeyPrompt,
        connectionID id: UUID
    ) async -> Bool {
        guard connectionID == id, phase == .connecting else { return false }
        completeHostKeyConfirmation(accepted: false)
        return await withCheckedContinuation { continuation in
            pendingHostKey = prompt
            hostKeyContinuation = continuation
        }
    }

    private func completeHostKeyConfirmation(accepted: Bool) {
        pendingHostKey = nil
        let continuation = hostKeyContinuation
        hostKeyContinuation = nil
        continuation?.resume(returning: accepted)
    }

    private func finishConnection(id: UUID, phase newPhase: Phase) {
        guard connectionID == id else { return }
        completeHostKeyConfirmation(accepted: false)
        connectionTask = nil
        client = nil
        credentials = nil
        Task { [input] in await input.clear(connectionID: id) }
        if let terminalView {
            clearTerminal(terminalView)
        }
        terminalView = nil
        phase = newPhase
    }

    private func closeCurrentConnection() {
        let oldConnectionID = connectionID
        connectionID = UUID()
        completeHostKeyConfirmation(accepted: false)

        let oldTask = connectionTask
        connectionTask = nil
        oldTask?.cancel()

        let oldClient = client
        client = nil
        Task {
            if let oldClient {
                try? await oldClient.close()
            }
            await input.clear(connectionID: oldConnectionID)
        }
    }

    private func clearTerminal(_ view: TerminalView) {
        _ = view.resignFirstResponder()
        view.getTerminal().clearScrollback()
        view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
    }
}
