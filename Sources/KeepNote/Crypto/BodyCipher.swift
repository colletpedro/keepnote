import CryptoKit
import Foundation

enum CipherError: LocalizedError {
    case badCiphertext
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .badCiphertext: return "A note body could not be decrypted."
        case .notUTF8: return "A decrypted note body was not valid UTF-8."
        }
    }
}

/// Seals and opens note bodies with AES-GCM.
///
/// The nonce is stored in its own column rather than inside
/// `SealedBox.combined`, so the schema stays explicit and a future key
/// rotation can rewrite bodies without re-parsing blobs. `ciphertext` holds
/// the ciphertext followed by the 16-byte tag.
struct BodyCipher: Sendable {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// The cipher for this Mac's notes. The key comes from the Keychain the
    /// first time only; see `KeychainKeyStore.sessionKeyLoadingOnce`.
    @MainActor
    static func makeDefault() throws -> BodyCipher {
        BodyCipher(key: try KeychainKeyStore.sessionKeyLoadingOnce())
    }

    func seal(_ plaintext: String) throws -> (ciphertext: Data, nonce: Data) {
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce)
        var payload = box.ciphertext
        payload.append(box.tag)
        return (payload, Data(nonce))
    }

    func open(ciphertext: Data, nonce: Data) throws -> String {
        guard ciphertext.count >= 16 else { throw CipherError.badCiphertext }
        let tagRange = ciphertext.index(ciphertext.endIndex, offsetBy: -16)..<ciphertext.endIndex
        let body = ciphertext[ciphertext.startIndex..<tagRange.lowerBound]
        let tag = ciphertext[tagRange]
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce),
                ciphertext: body,
                tag: tag
            )
            let opened = try AES.GCM.open(box, using: key)
            guard let string = String(data: opened, encoding: .utf8) else { throw CipherError.notUTF8 }
            return string
        } catch is CipherError {
            throw CipherError.notUTF8
        } catch {
            throw CipherError.badCiphertext
        }
    }
}
