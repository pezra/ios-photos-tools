import Foundation
import S3Kit

/// Wraps a background `URLSession` so uploads keep going while the app is suspended or terminated.
final class UploadSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "org.barelyenough.ios-photos-tools.uploads"
    static let shared = UploadSession()

    private(set) var session: URLSession!
    private let lock = NSLock()
    private var responseBodies: [Int: Data] = [:]
    private var completionHandler: (() -> Void)?

    /// Set when iOS relaunches the app to deliver upload events; called once they've been handled.
    var backgroundCompletionHandler: (() -> Void)? {
        get { lock.withLock { completionHandler } }
        set { lock.withLock { completionHandler = newValue } }
    }

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func activate() {
        _ = session
    }

    /// `mustNotExist` makes the bucket refuse the upload if something is already at that key, as a
    /// last guard against overwriting a different picture.
    func upload(file: URL, to url: URL, contentType: String, resourceID: String, allowCellular: Bool, mustNotExist: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if mustNotExist { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        request.allowsCellularAccess = allowCellular
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = resourceID
        task.resume()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Only kept so failures can report S3's error code; cap it in case of a large body.
        lock.withLock {
            var body = responseBodies[dataTask.taskIdentifier, default: Data()]
            if body.count < 8192 { body.append(data) }
            responseBodies[dataTask.taskIdentifier] = body
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = lock.withLock { responseBodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let resourceID = task.taskDescription else { return }

        let store = BackupStore.shared
        let stagedName = store.stagedName(forResource: resourceID)
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0

        if let error {
            store.markFailed(resourceID, error: error.localizedDescription)
        } else if (200..<300).contains(status) {
            store.markDone(resourceID)
        } else if status == 412 {
            // Something's already there. The next pass compares it: the same photo (an earlier
            // upload whose response was lost) is adopted, and anything else gets a new name.
            store.retirePaths(forResource: resourceID)
        } else {
            store.markFailed(resourceID, error: S3Error.from(status: status, body: body).localizedDescription)
        }
        Staging.remove(stagedName)

        Task { @MainActor in BackupStatus.shared.refreshCounts() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
