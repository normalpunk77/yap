import Foundation
import Security

public enum GoogleAuthError: Error, Equatable {
    case badPrivateKey
    case signingFailed
    case tokenStatus(Int)
    case noAccessToken
}

/// The fields we need from a Google service-account JSON key file.
public struct ServiceAccount: Sendable, Equatable {
    public let clientEmail: String
    public let privateKeyPEM: String
    public let projectID: String

    public init?(json: String) {
        guard
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let email = obj["client_email"] as? String, !email.isEmpty,
            let key = obj["private_key"] as? String, !key.isEmpty,
            let project = obj["project_id"] as? String, !project.isEmpty
        else { return nil }
        self.clientEmail = email
        self.privateKeyPEM = key
        self.projectID = project
    }
}

/// Mints and caches a Vertex OAuth access token from a service-account key, entirely in Swift
/// (no sidecar). JWT is RS256-signed with the SA private key via the Security framework.
public actor GoogleServiceAccountAuth {
    private let account: ServiceAccount
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var cachedToken: String?
    private var expiry: Date = .distantPast
    /// The in-flight mint, if one is already running. A second caller arriving during the token
    /// exchange (the actor is released at the network `await`) awaits THIS instead of starting a
    /// second JWT-bearer exchange — one token per refresh, not one per concurrent caller.
    private var inflight: Task<String, Error>?

    public init(account: ServiceAccount,
                session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.account = account
        self.session = session
        self.now = now
    }

    public func accessToken() async throws -> String {
        if let cachedToken, now() < expiry.addingTimeInterval(-60) { return cachedToken }
        if let inflight { return try await inflight.value }
        let task = Task { try await mintToken() }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    private func mintToken() async throws -> String {
        let jwt = try makeJWT()
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        req.httpBody = form.data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw GoogleAuthError.tokenStatus(code) }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = obj["access_token"] as? String
        else { throw GoogleAuthError.noAccessToken }
        let ttl = (obj["expires_in"] as? Double) ?? 3600
        cachedToken = token
        expiry = now().addingTimeInterval(ttl)
        return token
    }

    func makeJWT() throws -> String {
        let iat = Int(now().timeIntervalSince1970)
        let exp = iat + 3600
        let header = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": account.clientEmail,
            "scope": "https://www.googleapis.com/auth/cloud-platform",
            "aud": "https://oauth2.googleapis.com/token",
            "iat": iat,
            "exp": exp,
        ]
        let h = try JSONSerialization.data(withJSONObject: header).base64urlEncodedString()
        let c = try JSONSerialization.data(withJSONObject: claims).base64urlEncodedString()
        let signingInput = "\(h).\(c)"
        let sig = try Self.signRS256(signingInput, pemPKCS8: account.privateKeyPEM)
        return "\(signingInput).\(sig)"
    }

    /// Sign `signingInput` with RS256 using a PKCS#8 PEM private key (the format in SA JSON).
    static func signRS256(_ signingInput: String, pemPKCS8: String) throws -> String {
        let der = try pkcs1DER(fromPEM: pemPKCS8)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            error?.release()   // Security hands back a +1-retained CFError on failure; don't leak it
            throw GoogleAuthError.badPrivateKey
        }
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData, &error
        ) else {
            error?.release()
            throw GoogleAuthError.signingFailed
        }
        return (signature as Data).base64urlEncodedString()
    }

    /// Strip PEM armor + the fixed 26-byte PKCS#8 RSA wrapper to get the PKCS#1 RSAPrivateKey
    /// DER that SecKeyCreateWithData expects. (SA keys are unencrypted PKCS#8.)
    static func pkcs1DER(fromPEM pem: String) throws -> Data {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\n", with: "\n")   // JSON-escaped newlines
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let pkcs8 = Data(base64Encoded: base64) else { throw GoogleAuthError.badPrivateKey }
        let prefixLen = 26
        guard pkcs8.count > prefixLen else { throw GoogleAuthError.badPrivateKey }
        return pkcs8.subdata(in: prefixLen ..< pkcs8.count)
    }

    /// Inverse of pkcs1DER: wrap a PKCS#1 DER into a PKCS#8 PEM (test helper).
    static func pkcs8PEM(fromPKCS1DER pkcs1: Data) -> String {
        let header: [UInt8] = [
            0x30, 0x82, 0x00, 0x00, 0x02, 0x01, 0x00, 0x30, 0x0d, 0x06, 0x09, 0x2a,
            0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x04, 0x82,
            0x00, 0x00,
        ]
        var inner = header
        // length of the inner OCTET STRING (pkcs1)
        inner[24] = UInt8((pkcs1.count >> 8) & 0xff)
        inner[25] = UInt8(pkcs1.count & 0xff)
        var body = Data(inner) ; body.append(pkcs1)
        // outer SEQUENCE length
        let total = body.count - 4
        body[2] = UInt8((total >> 8) & 0xff)
        body[3] = UInt8(total & 0xff)
        let b64 = body.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PRIVATE KEY-----\n\(b64)\n-----END PRIVATE KEY-----\n"
    }
}

extension Data {
    func base64urlEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64urlEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
}
