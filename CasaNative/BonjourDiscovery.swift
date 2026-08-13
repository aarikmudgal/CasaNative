import Combine
import Foundation
import Network

@MainActor
public final class BonjourDiscovery: ObservableObject {
    public enum ResolutionError: LocalizedError, Sendable {
        case failed(String)
        case unresolved

        public var errorDescription: String? {
            switch self {
            case let .failed(message):
                "Could not resolve the advertised server: \(message)"
            case .unresolved:
                "The advertised service did not resolve to a host and port."
            }
        }
    }

    public enum State: Equatable, Sendable {
        case stopped
        case searching
        case ready
        case failed(String)
    }

    public enum Transport: String, CaseIterable, Hashable, Sendable {
        case casaos
        case http
        case https

        fileprivate var serviceType: String {
            switch self {
            case .casaos:
                "_casaos._tcp"
            case .http:
                "_http._tcp"
            case .https:
                "_https._tcp"
            }
        }
    }

    public struct DiscoveredService: Identifiable, Hashable, Sendable {
        public let name: String
        public let type: String
        public let domain: String
        public let transport: Transport

        public var id: String {
            "\(transport.rawValue):\(name):\(type):\(domain)"
        }

        public var displayName: String {
            name
        }

        public var endpoint: NWEndpoint {
            .service(name: name, type: type, domain: domain, interface: nil)
        }

        public init(
            name: String,
            type: String,
            domain: String,
            transport: Transport
        ) {
            self.name = name
            self.type = type
            self.domain = domain
            self.transport = transport
        }
    }

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var services: [DiscoveredService] = []

    private let queue = DispatchQueue(label: "com.local.CasaNative.bonjour")
    private var browsers: [Transport: NWBrowser] = [:]
    private var resultsByTransport: [Transport: [DiscoveredService]] = [:]
    private var readyTransports: Set<Transport> = []
    private var generation: UInt = 0

    public init() {}

    public func start() {
        generation &+= 1
        cancelBrowsers()
        resultsByTransport.removeAll()
        readyTransports.removeAll()
        services = []
        state = .searching

        let currentGeneration = generation
        for transport in Transport.allCases {
            let browser = NWBrowser(
                for: .bonjour(type: transport.serviceType, domain: nil),
                using: .tcp
            )

            browser.stateUpdateHandler = { [weak self] browserState in
                let update = BrowserUpdate(browserState)
                Task { @MainActor [weak self] in
                    self?.receive(
                        update,
                        for: transport,
                        generation: currentGeneration
                    )
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let discovered = results.compactMap { result -> DiscoveredService? in
                    guard case let .service(name, type, domain, _) = result.endpoint else {
                        return nil
                    }
                    return DiscoveredService(
                        name: name,
                        type: type,
                        domain: domain,
                        transport: transport
                    )
                }
                Task { @MainActor [weak self] in
                    self?.receive(
                        discovered,
                        for: transport,
                        generation: currentGeneration
                    )
                }
            }

            browsers[transport] = browser
            browser.start(queue: queue)
        }
    }

    public func stop() {
        generation &+= 1
        cancelBrowsers()
        resultsByTransport.removeAll()
        readyTransports.removeAll()
        services = []
        state = .stopped
    }

    public func resolve(_ service: DiscoveredService) async throws -> ServerEndpoint {
        let connection = NWConnection(to: service.endpoint, using: .tcp)
        let (host, port): (String, UInt16) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        guard case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint else {
                            connection.cancel()
                            continuation.resume(throwing: ResolutionError.unresolved)
                            return
                        }
                        connection.cancel()
                        continuation.resume(returning: (host.debugDescription, port.rawValue))
                    case let .failed(error):
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(throwing: ResolutionError.failed(error.localizedDescription))
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }

        let scheme = service.transport == .https ? "https" : "http"
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let renderedHost = cleanHost.contains(":")
            ? "[\(cleanHost.replacingOccurrences(of: "%", with: "%25"))]"
            : cleanHost
        return try ServerEndpoint(
            "\(scheme)://\(renderedHost):\(port)",
            source: .bonjour
        )
    }

    private func cancelBrowsers() {
        browsers.values.forEach { $0.cancel() }
        browsers.removeAll()
    }

    private func receive(
        _ update: BrowserUpdate,
        for transport: Transport,
        generation: UInt
    ) {
        guard generation == self.generation else {
            return
        }

        switch update {
        case .ready:
            readyTransports.insert(transport)
            state = .ready
        case .waiting:
            if readyTransports.isEmpty {
                state = .searching
            }
        case let .failed(message):
            readyTransports.remove(transport)
            if readyTransports.isEmpty {
                state = .failed(message)
            }
        case .cancelled:
            break
        }
    }

    private func receive(
        _ discovered: [DiscoveredService],
        for transport: Transport,
        generation: UInt
    ) {
        guard generation == self.generation else {
            return
        }
        resultsByTransport[transport] = discovered
        services = resultsByTransport.values
            .flatMap { $0 }
            .sorted {
                if $0.name.caseInsensitiveCompare($1.name) == .orderedSame {
                    return $0.id < $1.id
                }
                return $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private enum BrowserUpdate: Sendable {
        case ready
        case waiting
        case failed(String)
        case cancelled

        init(_ state: NWBrowser.State) {
            switch state {
            case .setup, .waiting:
                self = .waiting
            case .ready:
                self = .ready
            case let .failed(error):
                self = .failed(error.localizedDescription)
            case .cancelled:
                self = .cancelled
            @unknown default:
                self = .waiting
            }
        }
    }
}
