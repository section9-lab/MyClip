import CryptoKit
import Foundation

/// Temporary fixture keys only; production keys never enter the test suite.
@main struct FixtureCrypto {
    static func main() throws {
        let arguments = CommandLine.arguments
        switch arguments[1] {
        case "generate":
            let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
            let key = Curve25519.Signing.PrivateKey()
            let privateURL = directory.appendingPathComponent("private-key")
            try key.rawRepresentation.base64EncodedString().write(to: privateURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
            try key.publicKey.rawRepresentation.base64EncodedString().write(
                to: directory.appendingPathComponent("public-key"), atomically: true, encoding: .utf8)
        case "verify":
            let publicData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicData)!)
            let signature = Data(base64Encoded: arguments[3])!
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[4]))
            if !key.isValidSignature(signature, for: data) { exit(1) }
        default:
            exit(2)
        }
    }
}
