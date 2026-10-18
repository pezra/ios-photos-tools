import XCTest
@testable import S3Kit

/// Expected values come from the worked examples in the AWS S3 SigV4 documentation.
final class SigV4Tests: XCTestCase {
    private let exampleDate = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    private func awsExampleClient(pathStyle: Bool = false) throws -> S3Client {
        try S3Client(config: S3Config(
            endpoint: URL(string: "https://s3.amazonaws.com")!,
            region: "us-east-1",
            bucket: "examplebucket",
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            usePathStyle: pathStyle
        ))
    }

    func testGetObjectWithAuthorizationHeader() throws {
        let request = try awsExampleClient().signedRequest(
            method: "GET",
            key: "test.txt",
            headers: ["Range": "bytes=0-9"],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            date: exampleDate
        )
        XCTAssertEqual(request.url?.absoluteString, "https://examplebucket.s3.amazonaws.com/test.txt")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
                + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
                + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
    }

    func testPutObjectWithAuthorizationHeader() throws {
        let request = try awsExampleClient().signedRequest(
            method: "PUT",
            key: "test$file.text",
            headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"],
            payloadHash: SigV4.sha256Hex(Data("Welcome to Amazon S3.".utf8)),
            date: exampleDate
        )
        XCTAssertEqual(request.url?.absoluteString, "https://examplebucket.s3.amazonaws.com/test%24file.text")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
                + "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,"
                + "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
        )
    }

    func testPresignedURL() throws {
        let url = try awsExampleClient().presignedURL(method: "GET", key: "test.txt", expiresIn: 86400, date: exampleDate)
        XCTAssertEqual(
            url.absoluteString,
            "https://examplebucket.s3.amazonaws.com/test.txt"
                + "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
                + "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
                + "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
                + "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
        )
    }

    func testPathStyleWithCustomEndpointAndEncodedKey() throws {
        let client = try S3Client(config: S3Config(
            endpoint: URL(string: "http://minio.local:9000/")!,
            region: "us-east-1",
            bucket: "photos",
            accessKeyID: "key",
            secretAccessKey: "secret",
            usePathStyle: true
        ))
        let url = client.presignedURL(method: "PUT", key: "2024/05/My Photo+1é.HEIC", expiresIn: 60, date: exampleDate)
        XCTAssertTrue(
            url.absoluteString.hasPrefix("http://minio.local:9000/photos/2024/05/My%20Photo%2B1%C3%A9.HEIC?X-Amz-Algorithm="),
            url.absoluteString
        )
    }

    func testInvalidEndpointRejected() {
        XCTAssertThrowsError(try S3Client(config: S3Config(
            endpoint: URL(string: "s3.amazonaws.com")!,
            region: "us-east-1", bucket: "b", accessKeyID: "k", secretAccessKey: "s", usePathStyle: true
        )))
    }

    func testErrorParsing() {
        let body = Data("<Error><Code>SignatureDoesNotMatch</Code><Message>Bad sig</Message></Error>".utf8)
        XCTAssertEqual(S3Error.from(status: 403, body: body), .http(status: 403, code: "SignatureDoesNotMatch", message: "Bad sig"))
    }
}
