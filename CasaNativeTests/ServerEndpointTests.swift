import XCTest
@testable import CasaNative

final class ServerEndpointTests: XCTestCase {
    func testShortHostnameWithTrailingSlashNormalizesToRoot() throws {
        let endpoint = try ServerEndpoint("rpi/", source: .manual)

        XCTAssertEqual(endpoint.url.absoluteString, "http://rpi")
    }

    func testBareHostUsesHTTPAndNormalizesCaseAndWhitespace() throws {
        let endpoint = try ServerEndpoint(
            "  CasaOS.LOCAL:8080  ",
            source: .manual
        )

        XCTAssertEqual(endpoint.url.absoluteString, "http://casaos.local:8080")
        XCTAssertEqual(endpoint.source, .manual)
    }

    func testExplicitURLKeepsPathAndRemovesTrailingSlashes() throws {
        let endpoint = try ServerEndpoint(
            "HTTPS://CasaOS.LOCAL/dashboard///",
            source: .tailscale
        )

        XCTAssertEqual(
            endpoint.url.absoluteString,
            "https://casaos.local/dashboard"
        )
    }

    func testBareIPv6AddressIsBracketed() throws {
        let endpoint = try ServerEndpoint("2001:db8::42", source: .manual)
        let origin = try EndpointOrigin(endpoint: endpoint.url)

        XCTAssertEqual(endpoint.url.absoluteString, "http://[2001:db8::42]")
        XCTAssertEqual(origin.rawValue, "http://[2001:db8::42]")
    }

    func testEndpointOriginDropsPathDefaultPortAndTrailingDNSDot() throws {
        let origin = try EndpointOrigin(
            endpoint: "HTTP://CasaOS.LOCAL.:80/api/v1/"
        )

        XCTAssertEqual(origin.rawValue, "http://casaos.local")
    }

    func testEndpointOriginPreservesSchemeAndNonDefaultPort() throws {
        let https = try EndpointOrigin(
            endpoint: "https://CASAOS.LOCAL.:443/dashboard"
        )
        let customPort = try EndpointOrigin(
            endpoint: "https://CASAOS.LOCAL.:8443/dashboard"
        )

        XCTAssertEqual(https.rawValue, "https://casaos.local")
        XCTAssertEqual(customPort.rawValue, "https://casaos.local:8443")
        XCTAssertNotEqual(https, customPort)
    }

    func testRejectsHTTPTailscaleFQDNButAllowsSupportedAlternatives() throws {
        XCTAssertEqual(
            ServerEndpoint.ValidationError.insecureTailscaleFQDN.errorDescription,
            "HTTP cannot use a full Tailscale .ts.net hostname. Enter the short MagicDNS hostname or use HTTPS."
        )
        assertValidationError(
            "casaos.example-tailnet.ts.net",
            equals: .insecureTailscaleFQDN
        )
        assertValidationError(
            "http://casaos.example-tailnet.ts.net:8080",
            equals: .insecureTailscaleFQDN
        )

        let shortName = try ServerEndpoint("casaos", source: .tailscale)
        let secureFQDN = try ServerEndpoint(
            "https://casaos.example-tailnet.ts.net",
            source: .tailscale
        )

        XCTAssertEqual(shortName.url.absoluteString, "http://casaos")
        XCTAssertEqual(
            secureFQDN.url.absoluteString,
            "https://casaos.example-tailnet.ts.net"
        )
    }

    func testRejectsCredentialsQueryFragmentAndInvalidPort() {
        assertValidationError(
            "http://user:password@casaos.local",
            equals: .credentialsNotAllowed
        )
        assertValidationError(
            "http://casaos.local?mode=admin",
            equals: .queryNotAllowed
        )
        assertValidationError(
            "http://casaos.local#apps",
            equals: .fragmentNotAllowed
        )
        assertValidationError(
            "casaos.local:70000",
            equals: .invalidPort
        )
    }

    private func assertValidationError(
        _ input: String,
        equals expected: ServerEndpoint.ValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ServerEndpoint(input, source: .manual),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ServerEndpoint.ValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
