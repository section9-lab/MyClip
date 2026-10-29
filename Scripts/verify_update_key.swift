import CryptoKit
import Foundation

private struct SigningConfiguration: Decodable {
    let publicKey: String
    enum CodingKeys: String, CodingKey {
        case publicKey = "SUPublicEDKey"
    }
}

// Read the secret only from stdin. Sparkle can warn about a mismatched key yet
// exit successfully, so validate its public identity independently before signing.
do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let encoded = String(data: input, encoding: .utf8),
        let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
        seed.count == 32
    else {
        throw NSError(domain: "MyClip.UpdateSigning", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Expected a 32-byte Ed25519 seed exported by Sparkle generate_keys."
        ])
    }
    let infoData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let info = try PropertyListDecoder().decode(SigningConfiguration.self, from: infoData)
    let expected = Data(base64Encoded: info.publicKey)
    let actual = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    guard expected == actual else {
        throw NSError(domain: "MyClip.UpdateSigning", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Update signing key does not match the app's SUPublicEDKey."
        ])
    }
} catch {
    fputs("Update signing validation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
