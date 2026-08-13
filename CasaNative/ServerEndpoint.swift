import Foundation

public struct ServerEndpoint: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, CaseIterable, Hashable, Sendable {
        case manual
        case bonjour
        case tailscale
    }

    public enum ValidationError: LocalizedError, Equatable, Sendable {
        case emptyInput
        case invalidURL
        case unsupportedScheme(String)
        case missingHost
        case invalidPort
        case credentialsNotAllowed
        case queryNotAllowed
        case fragmentNotAllowed
        case insecureTailscaleFQDN

        public var errorDescription: String? {
            switch self {
            case .emptyInput:
                "Enter a server hostname or URL."
            case .invalidURL:
                "The server address is not a valid URL."
            case let .unsupportedScheme(scheme):
                "The \(scheme) URL scheme is not supported. Use HTTP or HTTPS."
            case .missingHost:
                "The server address must include a hostname or IP address."
            case .invalidPort:
                "The server port must be between 1 and 65535."
            case .credentialsNotAllowed:
                "Credentials cannot be included in the server URL."
            case .queryNotAllowed:
                "The server URL cannot include a query."
            case .fragmentNotAllowed:
                "The server URL cannot include a fragment."
            case .insecureTailscaleFQDN:
                "HTTP cannot use a full Tailscale .ts.net hostname. Enter the short MagicDNS hostname or use HTTPS."
            }
        }
    }

    public let url: URL
    public let source: Source

    public var id: String {
        "\(source.rawValue):\(url.absoluteString)"
    }

    public init(_ input: String, source: Source) throws {
        url = try Self.normalize(input)
        self.source = source
    }

    public init(url: URL, source: Source) throws {
        try self.init(url.absoluteString, source: source)
    }

    public static func normalize(_ input: String) throws -> URL {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw ValidationError.emptyInput
        }

        let hasExplicitScheme = input.range(of: "://") != nil
        let candidate: String

        if hasExplicitScheme {
            candidate = input
        } else {
            var authority = input
            while authority.hasSuffix("/") {
                authority.removeLast()
            }
            guard !authority.isEmpty,
                  !authority.contains("/"),
                  !authority.contains("?"),
                  !authority.contains("#") else {
                throw ValidationError.invalidURL
            }
            candidate = "http://\(try normalizedAuthority(authority))"
        }

        guard var components = URLComponents(string: candidate),
              let rawScheme = components.scheme else {
            throw ValidationError.invalidURL
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw ValidationError.unsupportedScheme(rawScheme)
        }
        guard components.user == nil, components.password == nil else {
            throw ValidationError.credentialsNotAllowed
        }
        guard components.percentEncodedQuery == nil else {
            throw ValidationError.queryNotAllowed
        }
        guard components.percentEncodedFragment == nil else {
            throw ValidationError.fragmentNotAllowed
        }
        guard let host = components.host,
              !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ValidationError.missingHost
        }
        let normalizedHost = host.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        )
        if scheme == "http", normalizedHost.hasSuffix(".ts.net") {
            throw ValidationError.insecureTailscaleFQDN
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw ValidationError.invalidPort
        }

        components.scheme = scheme
        components.host = host.lowercased()
        while components.percentEncodedPath.count > 1,
              components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }

        guard let url = components.url else {
            throw ValidationError.invalidURL
        }
        return url
    }

    private static func normalizedAuthority(_ input: String) throws -> String {
        if input.hasPrefix("[") {
            guard let closingBracket = input.firstIndex(of: "]") else {
                throw ValidationError.invalidURL
            }
            let suffix = input[input.index(after: closingBracket)...]
            if suffix.isEmpty {
                return input
            }
            guard suffix.first == ":" else {
                throw ValidationError.invalidURL
            }
            try validatePort(suffix.dropFirst())
            return input
        }

        let colonCount = input.reduce(into: 0) { count, character in
            if character == ":" {
                count += 1
            }
        }

        if colonCount > 1 {
            let escaped = input.replacingOccurrences(of: "%", with: "%25")
            return "[\(escaped)]"
        }
        if colonCount == 1 {
            guard let separator = input.lastIndex(of: ":") else {
                throw ValidationError.invalidURL
            }
            let host = input[..<separator]
            let port = input[input.index(after: separator)...]
            guard !host.isEmpty else {
                throw ValidationError.missingHost
            }
            try validatePort(port)
        }
        return input
    }

    private static func validatePort(_ value: Substring) throws {
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              let port = Int(value),
              (1...65_535).contains(port) else {
            throw ValidationError.invalidPort
        }
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .url)
        let source = try container.decode(Source.self, forKey: .source)
        do {
            try self.init(value, source: source)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .url,
                in: container,
                debugDescription: "Invalid server endpoint: \(error.localizedDescription)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url.absoluteString, forKey: .url)
        try container.encode(source, forKey: .source)
    }
}
