import Foundation
import Security

/// Imports a local accessory identity into this device's Keychain.
/// Only the legacy Documents staging import removes its original files.
enum AccessoryIdentityStore {
    private static let service = "local.tds.carkit.mfi-identity"
    private static let chainAccount = "certificate-chain"
    private static let leafAccount = "leaf-certificate"
    private static let keyTag = Data("local.tds.carkit.mfi-identity.private-key".utf8)
    private static let maximumIdentityFileSize = 65_536

    private struct StoredIdentity {
        let chain: Data
        let leaf: Data
        let key: SecKey
    }

    /// A failed replacement can leave the stored identity unavailable. The UI
    /// must reload it in that case instead of retaining its old in-memory status.
    enum ImportFailure: LocalizedError {
        case notSaved(String)
        case previousRestored(String)
        case recoveryFailed(importError: String, recoveryError: String)

        var requiresIdentityReload: Bool {
            if case .previousRestored = self { return false }
            return true
        }

        var errorDescription: String? {
            switch self {
            case .notSaved(let message):
                return "身份未能保存到 Keychain，请重试。\(message)"
            case .previousRestored(let message):
                return "新身份未能保存；原身份已恢复并通过自检，可继续使用。\(message)"
            case .recoveryFailed(let importError, let recoveryError):
                return "新身份保存失败，且无法确认原身份已恢复。请重新导入有效身份。保存错误：\(importError)；恢复错误：\(recoveryError)"
            }
        }
    }

    static func load() throws -> AccessoryIdentity {
        let chain = try readData(account: chainAccount)
        let leaf = try readData(account: leafAccount)
        let key = try readPrivateKey()
        return try AccessoryIdentity(certificateChain: chain, leafCertificate: leaf, privateKey: key)
    }

    /// Loads an MFi identity bundled inside the app (certificate.p7b, leaf.cer, private.x963).
    /// Used so a sideloaded build works without a per-device import step.
    static func loadFromBundle() throws -> AccessoryIdentity {
        guard let chainURL = Bundle.main.url(forResource: "certificate", withExtension: "p7b"),
              let leafURL = Bundle.main.url(forResource: "leaf", withExtension: "cer"),
              let keyURL = Bundle.main.url(forResource: "private", withExtension: "x963") else {
            throw StoreError.identityMissing
        }
        let chain = try readBounded(chainURL)
        let leaf = try readBounded(leafURL)
        var keyData = try readBounded(keyURL)
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        return try AccessoryIdentity(certificateChain: chain, leafCertificate: leaf, privateKeyX963: keyData)
    }

    static func importFromDocuments() throws -> AccessoryIdentity {
        let directory = try stagingDirectory()
        let identity = try importFromDirectory(directory)
        for name in ["certificate.p7b", "leaf.cer", "private.x963"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: directory)
        return identity
    }

    /// Validates a user-selected folder, then stores the identity in this app's Keychain.
    /// Never deletes or modifies the user's original files.
    static func importFromDirectory(_ directory: URL) throws -> AccessoryIdentity {
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw StoreError.invalidStagingFile("请选择包含三个身份文件的文件夹")
        }
        let chainURL = directory.appendingPathComponent("certificate.p7b")
        let leafURL = directory.appendingPathComponent("leaf.cer")
        let keyURL = directory.appendingPathComponent("private.x963")

        let chain = try readBounded(chainURL)
        let leaf = try readBounded(leafURL)
        var keyData = try readBounded(keyURL)
        defer { keyData.resetBytes(in: 0..<keyData.count) }

        _ = try AccessoryIdentity(certificateChain: chain, leafCertificate: leaf, privateKeyX963: keyData)
        // Keep a SecKey reference, never an exported copy of the previous key.
        // Unexpected Keychain read errors abort before changing any stored item.
        let previous = try storedIdentity()
        do {
            try replacePrivateKey(keyData)
            try replaceData(chain, account: chainAccount)
            try replaceData(leaf, account: leafAccount)
            return try load()
        } catch {
            let importError = error.localizedDescription
            if let previous {
                do {
                    try replacePrivateKey(previous.key)
                    try replaceData(previous.chain, account: chainAccount)
                    try replaceData(previous.leaf, account: leafAccount)
                    _ = try load()
                } catch {
                    // Preserve the remaining items for recovery; do not erase
                    // the previous identity again after a failed rollback.
                    throw ImportFailure.recoveryFailed(importError: importError,
                        recoveryError: error.localizedDescription)
                }
                throw ImportFailure.previousRestored(importError)
            }
            deleteStoredIdentity()
            throw ImportFailure.notSaved(importError)
        }
    }

    private static func storedIdentity() throws -> StoredIdentity? {
        do {
            return StoredIdentity(chain: try readData(account: chainAccount),
                leaf: try readData(account: leafAccount), key: try readPrivateKey())
        } catch StoreError.identityMissing {
            return nil
        }
    }

    static func deleteStoredIdentity() {
        SecItemDelete(privateKeyQuery() as CFDictionary)
        for account in [chainAccount, leafAccount] {
            SecItemDelete(dataQuery(account: account) as CFDictionary)
        }
    }

    private static func stagingDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw StoreError.documentsUnavailable
        }
        return documents.appendingPathComponent("IdentityImport", isDirectory: true)
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumIdentityFileSize else {
            throw StoreError.invalidStagingFile(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url, options: [.uncached])
        guard !data.isEmpty, data.count <= maximumIdentityFileSize else {
            throw StoreError.invalidStagingFile(url.lastPathComponent)
        }
        return data
    }

    private static func replacePrivateKey(_ representation: Data) throws {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256
        ]
        guard let key = SecKeyCreateWithData(representation as CFData, attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw StoreError.invalidPrivateKey
        }
        try replacePrivateKey(key)
    }

    private static func replacePrivateKey(_ key: SecKey) throws {
        let deleted = SecItemDelete(privateKeyQuery() as CFDictionary)
        if deleted != errSecItemNotFound { try requireSuccess(deleted) }
        var query = privateKeyQuery()
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueRef] = key
        try requireSuccess(SecItemAdd(query as CFDictionary, nil))
    }

    private static func readPrivateKey() throws -> SecKey {
        var query = privateKeyQuery()
        query[kSecReturnRef] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status != errSecItemNotFound else { throw StoreError.identityMissing }
        try requireSuccess(status)
        guard let key = value as! SecKey? else { throw StoreError.invalidPrivateKey }
        return key
    }

    private static func replaceData(_ data: Data, account: String) throws {
        let base = dataQuery(account: account)
        let deleted = SecItemDelete(base as CFDictionary)
        if deleted != errSecItemNotFound { try requireSuccess(deleted) }
        var query = base
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData] = data
        try requireSuccess(SecItemAdd(query as CFDictionary, nil))
    }

    private static func readData(account: String) throws -> Data {
        var query = dataQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status != errSecItemNotFound else { throw StoreError.identityMissing }
        try requireSuccess(status)
        guard let data = value as? Data else { throw StoreError.invalidStoredIdentity }
        return data
    }

    private static func privateKeyQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
    }

    private static func dataQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    private enum StoreError: LocalizedError {
        case documentsUnavailable
        case identityMissing
        case invalidStagingFile(String)
        case invalidPrivateKey
        case invalidStoredIdentity
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .documentsUnavailable: return "App 的 Documents 目录不可用"
            case .identityMissing: return "Keychain 中未存储 MFi 身份"
            case .invalidStagingFile(let name): return "身份导入文件缺失或无效：\(name)"
            case .invalidPrivateKey: return "导入的 P-256 私钥无效"
            case .invalidStoredIdentity: return "已存储的 MFi 身份无效"
            case .keychain(let status):
                return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain 错误 \(status)"
            }
        }
    }
}
