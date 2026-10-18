import Foundation

public struct S3Config: Sendable, Equatable {
    /// Service endpoint, e.g. `https://s3.us-east-1.amazonaws.com` or `https://<account>.r2.cloudflarestorage.com`.
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var accessKeyID: String
    public var secretAccessKey: String
    /// `https://endpoint/bucket/key` instead of `https://bucket.endpoint/key`. Most S3-compatible services want this.
    public var usePathStyle: Bool

    public init(endpoint: URL, region: String, bucket: String, accessKeyID: String, secretAccessKey: String, usePathStyle: Bool) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.usePathStyle = usePathStyle
    }
}

public enum S3Error: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case http(status: Int, code: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The endpoint must be a full URL such as https://s3.us-east-1.amazonaws.com"
        case let .http(status, code, message):
            return ["HTTP \(status)", code, message].compactMap { $0 }.joined(separator: ": ")
        }
    }

    /// Builds an error from an S3 XML error response body.
    public static func from(status: Int, body: Data) -> S3Error {
        let text = String(decoding: body, as: UTF8.self)
        func element(_ name: String) -> String? {
            guard let open = text.range(of: "<\(name)>"),
                  let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
            else { return nil }
            return String(text[open.upperBound..<close.lowerBound])
        }
        return .http(status: status, code: element("Code"), message: element("Message"))
    }
}

public struct S3Client: Sendable {
    public let config: S3Config

    public init(config: S3Config) throws {
        guard let scheme = config.endpoint.scheme, ["http", "https"].contains(scheme.lowercased()),
              config.endpoint.host?.isEmpty == false
        else { throw S3Error.invalidEndpoint }
        self.config = config
    }

    /// A URL that allows `method` on `key` without further credentials until it expires (max 7 days).
    public func presignedURL(method: String, key: String, expiresIn: Int, date: Date = Date()) -> URL {
        var (components, canonicalURI) = location(for: key)
        let (amzDate, dateStamp) = SigV4.timestamps(for: date)
        let scope = credentialScope(dateStamp)
        let query = [
            ("X-Amz-Algorithm", SigV4.algorithm),
            ("X-Amz-Credential", "\(config.accessKeyID)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expiresIn)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        let canonicalQuery = SigV4.canonicalQuery(query)
        let (canonicalHeaders, signedHeaders) = SigV4.canonicalHeaders(["host": hostHeader(components)])
        let signature = SigV4.signature(
            method: method,
            canonicalURI: canonicalURI,
            canonicalQuery: canonicalQuery,
            canonicalHeaders: canonicalHeaders,
            signedHeaders: signedHeaders,
            payloadHash: SigV4.unsignedPayload,
            amzDate: amzDate,
            scope: scope,
            signingKey: signingKey(dateStamp)
        )
        components.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=" + signature
        return components.url!
    }

    /// A request signed with an `Authorization` header. Valid for about 15 minutes from `date`.
    public func signedRequest(
        method: String,
        key: String?,
        query: [(String, String)] = [],
        headers: [String: String] = [:],
        payloadHash: String,
        date: Date = Date()
    ) -> URLRequest {
        var (components, canonicalURI) = location(for: key)
        let canonicalQuery = SigV4.canonicalQuery(query)
        components.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery

        let (amzDate, dateStamp) = SigV4.timestamps(for: date)
        let scope = credentialScope(dateStamp)
        var allHeaders = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        allHeaders["host"] = hostHeader(components)
        allHeaders["x-amz-date"] = amzDate
        allHeaders["x-amz-content-sha256"] = payloadHash
        let (canonicalHeaders, signedHeaders) = SigV4.canonicalHeaders(allHeaders)
        let signature = SigV4.signature(
            method: method,
            canonicalURI: canonicalURI,
            canonicalQuery: canonicalQuery,
            canonicalHeaders: canonicalHeaders,
            signedHeaders: signedHeaders,
            payloadHash: payloadHash,
            amzDate: amzDate,
            scope: scope,
            signingKey: signingKey(dateStamp)
        )

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        for (name, value) in allHeaders where name != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(
            "\(SigV4.algorithm) Credential=\(config.accessKeyID)/\(scope),SignedHeaders=\(signedHeaders),Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    public func putObject(key: String, data: Data, contentType: String?, session: URLSession = .shared) async throws {
        var headers: [String: String] = [:]
        if let contentType { headers["content-type"] = contentType }
        let request = signedRequest(method: "PUT", key: key, headers: headers, payloadHash: SigV4.sha256Hex(data))
        let (body, response) = try await session.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw S3Error.from(status: status, body: body) }
    }

    // MARK: - Private

    private func credentialScope(_ dateStamp: String) -> String {
        "\(dateStamp)/\(config.region)/s3/aws4_request"
    }

    private func signingKey(_ dateStamp: String) -> Data {
        SigV4.signingKey(secret: config.secretAccessKey, dateStamp: dateStamp, region: config.region)
    }

    /// URL components (without query) and canonical URI for an object, or the bucket when `key` is nil.
    private func location(for key: String?) -> (URLComponents, String) {
        var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)!
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        if config.usePathStyle {
            path += "/" + SigV4.uriEncode(config.bucket, encodeSlash: true)
        } else {
            components.host = "\(config.bucket).\(components.host ?? "")"
        }
        if let key { path += "/" + SigV4.uriEncode(key, encodeSlash: false) }
        if path.isEmpty { path = "/" }
        components.percentEncodedPath = path
        components.query = nil
        return (components, path)
    }

    private func hostHeader(_ components: URLComponents) -> String {
        let host = components.percentEncodedHost ?? ""
        return components.port.map { "\(host):\($0)" } ?? host
    }
}
