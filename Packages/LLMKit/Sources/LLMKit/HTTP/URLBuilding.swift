import Foundation

enum URLBuilding {
    /// Joins a base URL and a path without doubling or dropping slashes.
    static func url(_ base: URL, appending path: String) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        return URL(string: s + "/" + p) ?? base.appendingPathComponent(p)
    }

    static func jsonRequest(url: URL, method: String = "POST", body: JSONValue?, headers: [String: String], timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try body.encoded()
        }
        return request
    }
}
