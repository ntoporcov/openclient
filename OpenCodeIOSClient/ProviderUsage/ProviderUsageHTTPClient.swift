import Foundation

struct ProviderUsageHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { result, element in
            result[element.key.lowercased()] = element.value
        }
        self.body = body
    }

    func header(named name: String) -> String? {
        headers[name.lowercased()]
    }

    func retryDate(relativeTo now: Date) -> Date? {
        guard let value = header(named: "retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

protocol ProviderUsageHTTPTransport: Sendable {
    func send(
        _ request: URLRequest,
        allowedOrigin: URL,
        maximumResponseBytes: Int
    ) async throws -> ProviderUsageHTTPResponse
}

actor ProviderUsageHTTPClient: ProviderUsageHTTPTransport {
    private let configuration: URLSessionConfiguration

    init(sessionConfiguration: URLSessionConfiguration? = nil) {
        let configuration = sessionConfiguration?.copy() as? URLSessionConfiguration
            ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        self.configuration = configuration
    }

    func send(
        _ request: URLRequest,
        allowedOrigin: URL,
        maximumResponseBytes: Int
    ) async throws -> ProviderUsageHTTPResponse {
        guard maximumResponseBytes > 0 else {
            throw ProviderUsageError.invalidRequest
        }
        try Self.validate(request: request, allowedOrigin: allowedOrigin)
        return try await ProviderUsageBoundedRequest(
            configuration: configuration,
            maximumBytes: maximumResponseBytes
        ).load(request)
    }

    private static func validate(request: URLRequest, allowedOrigin: URL) throws {
        guard let originComponents = URLComponents(url: allowedOrigin, resolvingAgainstBaseURL: false),
              originComponents.scheme?.lowercased() == "https",
              let originHost = originComponents.host?.lowercased(),
              originComponents.user == nil,
              originComponents.password == nil,
              originComponents.query == nil,
              originComponents.fragment == nil else {
            throw ProviderUsageError.insecureTransport
        }
        guard let url = request.url,
              let requestComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              requestComponents.scheme?.lowercased() == "https" else {
            throw ProviderUsageError.insecureTransport
        }
        guard requestComponents.user == nil,
              requestComponents.password == nil,
              requestComponents.host?.lowercased() == originHost,
              effectivePort(requestComponents) == effectivePort(originComponents) else {
            throw ProviderUsageError.disallowedOrigin
        }
    }

    private static func effectivePort(_ components: URLComponents) -> Int {
        components.port ?? 443
    }
}

private final class ProviderUsageBoundedRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private let lock = NSLock()

    private var continuation: CheckedContinuation<ProviderUsageHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var wasCancelled = false
    private var rejectedRedirect = false

    init(configuration: URLSessionConfiguration, maximumBytes: Int) {
        self.configuration = configuration.copy() as? URLSessionConfiguration ?? configuration
        self.maximumBytes = maximumBytes
    }

    func load(_ request: URLRequest) async throws -> ProviderUsageHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if wasCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection newResponse: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        rejectedRedirect = true
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(ProviderUsageError.invalidResponse))
            return
        }
        if let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
           let byteCount = Int(contentLength.trimmingCharacters(in: .whitespacesAndNewlines)),
           byteCount > maximumBytes {
            completionHandler(.cancel)
            finish(.failure(ProviderUsageError.responseTooLarge))
            return
        }

        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let nextCount = data.count + chunk.count
        if nextCount <= maximumBytes {
            data.append(chunk)
        }
        lock.unlock()

        if nextCount > maximumBytes {
            dataTask.cancel()
            finish(.failure(ProviderUsageError.responseTooLarge))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let wasCancelled = wasCancelled
        let rejectedRedirect = rejectedRedirect
        let response = response
        let body = data
        lock.unlock()

        if wasCancelled {
            finish(.failure(CancellationError()))
            return
        }
        if rejectedRedirect {
            finish(.failure(ProviderUsageError.redirectRejected))
            return
        }
        if error != nil {
            finish(.failure(ProviderUsageError.network))
            return
        }
        guard let response else {
            finish(.failure(ProviderUsageError.invalidResponse))
            return
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, element in
            result[String(describing: element.key).lowercased()] = String(describing: element.value)
        }
        finish(.success(ProviderUsageHTTPResponse(
            statusCode: response.statusCode,
            headers: headers,
            body: body
        )))
    }

    private func cancel() {
        lock.lock()
        wasCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<ProviderUsageHTTPResponse, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        task = nil
        let session = session
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}
