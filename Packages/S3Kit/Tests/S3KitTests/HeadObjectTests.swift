import XCTest
@testable import S3Kit

final class HeadObjectTests: XCTestCase {
    /// Answers with the given status and headers, and records the request.
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var headers: [String: String] = [:]
        nonisolated(unsafe) static var request: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            Self.request = request
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: Self.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func head(status: Int, headers: [String: String] = [:]) async throws -> Int64? {
        Stub.status = status
        Stub.headers = headers
        Stub.request = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let client = try S3Client(config: S3Config(
            endpoint: URL(string: "https://s3.example.com")!, region: "auto", bucket: "b",
            accessKeyID: "id", secretAccessKey: "secret", usePathStyle: true))
        return try await client.headObject(key: "photos/2026/IMG 1.HEIC", session: URLSession(configuration: config))
    }

    func testReturnsTheSize() async throws {
        let size = try await head(status: 200, headers: ["Content-Length": "1234"])
        XCTAssertEqual(size, 1234)
        XCTAssertEqual(Stub.request?.httpMethod, "HEAD")
        XCTAssertEqual(Stub.request?.url?.path, "/b/photos/2026/IMG 1.HEIC")
    }

    func testNothingThereIsNil() async throws {
        let size = try await head(status: 404)
        XCTAssertNil(size)
    }

    func testOtherAnswersAreErrors() async throws {
        do {
            _ = try await head(status: 403)
            XCTFail("Expected an error")
        } catch let error as S3Error {
            XCTAssertEqual(error.status, 403)
        }
    }
}
