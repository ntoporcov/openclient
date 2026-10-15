import Foundation

/// Both auth-gate's bridge and DSH's cookie exchange use same-origin redirects.
/// Never forward login bodies or launch-token redirects to another authority.
final class DSHLoginRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL

    init(origin: URL) { self.origin = origin }

    func permits(_ url: URL) -> Bool {
        url.scheme == origin.scheme && url.host == origin.host
            && (url.port ?? (url.scheme == "https" ? 443 : 80)) == (origin.port ?? (origin.scheme == "https" ? 443 : 80))
            && url.user == nil && url.password == nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(permits) == true ? request : nil)
    }
}
