import Foundation
import CryptoKit

@main struct VerifyUpdate {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { exit(64) }
        let keyText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let publicData = Data(base64Encoded: keyText), let signature = Data(base64Encoded: CommandLine.arguments[3]) else { exit(1) }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
        guard key.isValidSignature(signature, for: archive) else {
            fputs("Update signature does not match the committed public key.\n", stderr)
            exit(1)
        }
        print("Verified update signature against the app public key.")
    }
}
