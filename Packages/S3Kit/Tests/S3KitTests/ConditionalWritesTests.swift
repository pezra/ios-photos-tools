import XCTest
@testable import S3Kit

final class ConditionalWritesTests: XCTestCase {
    /// Answers each request with the next status, and records the requests.
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var statuses: [Int] = []
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            Self.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.statuses.removeFirst(), httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<Error><Code>Nope</Code></Error>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func check(_ statuses: [Int]) async throws -> Bool {
        Stub.statuses = statuses
        Stub.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let client = try S3Client(config: S3Config(
            endpoint: URL(string: "https://s3.example.com")!, region: "auto", bucket: "b",
            accessKeyID: "id", secretAccessKey: "secret", usePathStyle: true))
        return try await client.supportsConditionalWrites(key: "photos/.photos-tools/check", session: URLSession(configuration: config))
    }

    func testRefusalMeansSupported() async throws {
        let supported = try await check([412])
        XCTAssertTrue(supported)
        XCTAssertEqual(Stub.requests.count, 1)
    }

    func testFirstWriteThenRefusalMeansSupported() async throws {
        let supported = try await check([200, 412])
        XCTAssertTrue(supported)
        XCTAssertEqual(Stub.requests.count, 2)
    }

    func testNotImplementedMeansUnsupported() async throws {
        let supported = try await check([501])
        XCTAssertFalse(supported)
    }

    func testServiceThatIgnoresTheHeaderIsUnsupported() async throws {
        let supported = try await check([200, 200])
        XCTAssertFalse(supported)
    }

    func testOtherAnswersAreErrorsNotAnAnswer() async throws {
        do {
            _ = try await check([403])
            XCTFail("Expected an error")
        } catch let error as S3Error {
            XCTAssertEqual(error.status, 403)
        }
    }

    func testAsksConditionallyAtTheGivenKey() async throws {
        _ = try await check([412])
        let request = try XCTUnwrap(Stub.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(request.url?.path, "/b/photos/.photos-tools/check")
    }
}
