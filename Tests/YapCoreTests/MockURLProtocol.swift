import Foundation

/// Intercepts URLSession requests in tests so no real network call is made. Set
/// `handler` to inspect the outgoing request and return the canned (status, body) or throw.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            // URLProtocol strips httpBody for some methods; expose it via httpBodyStream too.
            var req = request
            if req.httpBody == nil, let stream = req.httpBodyStream {
                req.httpBody = Data(reading: stream)
            }
            let (status, body) = try handler(req)
            let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private extension Data {
    init(reading input: InputStream) {
        self.init()
        input.open()
        defer { input.close() }
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while input.hasBytesAvailable {
            let read = input.read(&buffer, maxLength: size)
            if read <= 0 { break }
            append(buffer, count: read)
        }
    }
}
