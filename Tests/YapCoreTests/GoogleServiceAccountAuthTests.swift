import XCTest
import Security
@testable import YapCore

final class GoogleServiceAccountAuthTests: XCTestCase {
    override func tearDown() { MockURLProtocol.handler = nil; super.tearDown() }

    /// Generates a throwaway RSA key pair and returns (pkcs8 PEM private key, SecKey public key).
    private func makeTestKey() throws -> (pem: String, publicKey: SecKey) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        let pub = SecKeyCopyPublicKey(priv)!
        // Export the private key (PKCS#1 DER) and wrap it into a PKCS#8 PEM, matching what a
        // Google SA JSON contains.
        let pkcs1 = SecKeyCopyExternalRepresentation(priv, &error)! as Data
        let pem = GoogleServiceAccountAuth.pkcs8PEM(fromPKCS1DER: pkcs1)
        return (pem, pub)
    }

    func testServiceAccountParsesJSON() {
        let json = #"{"client_email":"a@b.iam.gserviceaccount.com","private_key":"-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n","project_id":"my-proj"}"#
        let sa = ServiceAccount(json: json)
        XCTAssertEqual(sa?.clientEmail, "a@b.iam.gserviceaccount.com")
        XCTAssertEqual(sa?.projectID, "my-proj")
    }

    func testServiceAccountRejectsMissingFields() {
        XCTAssertNil(ServiceAccount(json: #"{"client_email":"x"}"#))
    }

    func testPKCS8RoundTrip() throws {
        // Sanity-check the 26-byte PKCS#8 wrapper: unwrap(wrap(x)) == x.
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error)!
        let pkcs1 = SecKeyCopyExternalRepresentation(priv, &error)! as Data
        let pem = GoogleServiceAccountAuth.pkcs8PEM(fromPKCS1DER: pkcs1)
        let recovered = try GoogleServiceAccountAuth.pkcs1DER(fromPEM: pem)
        XCTAssertEqual(recovered, pkcs1)
    }

    func testRS256SignatureVerifies() throws {
        let (pem, publicKey) = try makeTestKey()
        let signingInput = "header.payload"
        let jwsSig = try GoogleServiceAccountAuth.signRS256(signingInput, pemPKCS8: pem)
        // Recover raw signature bytes from base64url and verify against the public key.
        let raw = Data(base64urlEncoded: jwsSig)!
        let ok = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                       Data(signingInput.utf8) as CFData, raw as CFData, nil)
        XCTAssertTrue(ok)
    }

    func testAccessTokenExchangeAndCache() async throws {
        let (pem, _) = try makeTestKey()
        let sa = ServiceAccount(json: """
        {"client_email":"a@b.iam.gserviceaccount.com","private_key":\(pemJSONEscaped(pem)),"project_id":"p"}
        """)!
        var calls = 0
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://oauth2.googleapis.com/token")
            calls += 1
            return (200, Data(#"{"access_token":"TOKEN123","expires_in":3600}"#.utf8))
        }
        let auth = GoogleServiceAccountAuth(account: sa, session: MockURLProtocol.session())
        let t1 = try await auth.accessToken()
        let t2 = try await auth.accessToken()   // cached: no second network call
        XCTAssertEqual(t1, "TOKEN123")
        XCTAssertEqual(t2, "TOKEN123")
        XCTAssertEqual(calls, 1)
    }

    private func pemJSONEscaped(_ pem: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [pem])
        let arr = String(data: data, encoding: .utf8)!   // ["...\n..."]
        return String(arr.dropFirst().dropLast())        // strip [ ]
    }
}
