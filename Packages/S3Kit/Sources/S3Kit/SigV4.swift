import CryptoKit
import Foundation

/// AWS Signature Version 4 primitives, as used by S3.
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html
enum SigV4 {
    static let algorithm = "AWS4-HMAC-SHA256"
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// Made once, since every signed request needs one. Formatting with it is thread-safe.
    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    static func timestamps(for date: Date) -> (amzDate: String, dateStamp: String) {
        let amzDate = amzDateFormatter.string(from: date)
        return (amzDate, String(amzDate.prefix(8)))
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// The payload hash of a request with no body.
    static let emptyPayloadHash = sha256Hex(Data())

    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func signingKey(secret: String, dateStamp: String, region: String, service: String = "s3") -> Data {
        let kDate = hmac(Data("AWS4\(secret)".utf8), dateStamp)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        return hmac(kService, "aws4_request")
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)

    /// RFC 3986 encoding as S3 expects it (uppercase hex, everything but unreserved characters encoded).
    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var out = ""
        for byte in string.utf8 {
            if unreserved.contains(byte) || (!encodeSlash && byte == UInt8(ascii: "/")) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(name: String, value: String)] = items.map {
            (uriEncode($0.0, encodeSlash: true), uriEncode($0.1, encodeSlash: true))
        }
        let sorted = encoded.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// Returns the canonical header block (each line newline-terminated) and the signed-headers list.
    static func canonicalHeaders(_ headers: [String: String]) -> (canonical: String, signed: String) {
        let normalized = headers
            .map { name, value in
                (name.lowercased(), value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
            }
            .sorted { $0.0 < $1.0 }
        let canonical = normalized.map { "\($0.0):\($0.1)\n" }.joined()
        let signed = normalized.map(\.0).joined(separator: ";")
        return (canonical, signed)
    }

    static func signature(
        method: String,
        canonicalURI: String,
        canonicalQuery: String,
        canonicalHeaders: String,
        signedHeaders: String,
        payloadHash: String,
        amzDate: String,
        scope: String,
        signingKey: Data
    ) -> String {
        let canonicalRequest = [method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let stringToSign = [algorithm, amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))]
            .joined(separator: "\n")
        return hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: signingKey)))
    }
}
