import XCTest
@testable import S3Kit

final class ListObjectsTests: XCTestCase {
    private func xml(_ contents: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>bucket</Name><Prefix>photos/</Prefix><KeyCount>2</KeyCount><MaxKeys>1000</MaxKeys>
          \(contents)
        </ListBucketResult>
        """.utf8)
    }

    func testParsesObjectsAndSizes() throws {
        let page = try S3ListPage(xml: xml("""
            <IsTruncated>false</IsTruncated>
            <Contents><Key>photos/2007/023 (2).JPG</Key><LastModified>2026-01-01T00:00:00.000Z</LastModified><ETag>"abc"</ETag><Size>1234</Size><StorageClass>STANDARD</StorageClass></Contents>
            <Contents><Key>photos/undated/R&amp;D/a.jpg</Key><Size>5000000000</Size></Contents>
            """))
        XCTAssertEqual(page.objects, [
            S3Object(key: "photos/2007/023 (2).JPG", size: 1234),
            S3Object(key: "photos/undated/R&D/a.jpg", size: 5_000_000_000),
        ])
        XCTAssertNil(page.nextContinuationToken)
    }

    func testTruncatedPageGivesToken() throws {
        let page = try S3ListPage(xml: xml("""
            <IsTruncated>true</IsTruncated><NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
            <Contents><Key>a</Key><Size>1</Size></Contents>
            """))
        XCTAssertEqual(page.nextContinuationToken, "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
    }

    func testEmptyListing() throws {
        let page = try S3ListPage(xml: xml("<IsTruncated>false</IsTruncated>"))
        XCTAssertTrue(page.objects.isEmpty)
        XCTAssertNil(page.nextContinuationToken)
    }

    func testCutOffListingIsAnError() {
        let whole = String(decoding: xml("<Contents><Key>a</Key><Size>1</Size></Contents>"), as: UTF8.self)
        let cutOff = Data(whole.prefix(whole.count - 30).utf8)
        XCTAssertThrowsError(try S3ListPage(xml: cutOff))
    }

    func testResponseThatIsNotAListingIsAnError() {
        XCTAssertThrowsError(try S3ListPage(xml: Data("<html><body>Sign in to the wifi</body></html>".utf8)))
        XCTAssertThrowsError(try S3ListPage(xml: Data()))
    }

    func testTruncatedPageWithNoTokenIsAnError() {
        XCTAssertThrowsError(try S3ListPage(xml: xml("<IsTruncated>true</IsTruncated>")))
    }

    func testListRequestIsSignedOverTheQuery() throws {
        let client = try S3Client(config: S3Config(
            endpoint: URL(string: "https://s3.amazonaws.com")!, region: "us-east-1", bucket: "examplebucket",
            accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", usePathStyle: true))
        let request = client.signedRequest(method: "GET", key: nil, query: [("list-type", "2"), ("prefix", "photos/")], payloadHash: SigV4.sha256Hex(Data()))
        XCTAssertEqual(request.url?.absoluteString, "https://s3.amazonaws.com/examplebucket?list-type=2&prefix=photos%2F")
    }
}
