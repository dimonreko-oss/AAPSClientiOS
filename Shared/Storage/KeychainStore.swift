import Security
import Foundation

enum KeychainKey: String, CaseIterable {
    case nsUrl
    case nsAccessToken
    case clientControlPairing

    /// Nightscout credentials only. `clientControlPairing` is deliberately excluded: it is the
    /// 32-byte HMAC secret for the command channel, and every copy path in this file targets the
    /// shared access group that the widget extension can also read. The widget only ever needs the
    /// NS URL and token — see `SharedConstants.pairingKeychain`.
    static let credentials: [KeychainKey] = [.nsUrl, .nsAccessToken]
}

final class KeychainStore {
    private let service: String
    /// nil means "whatever the process's default access group is". That is not a synonym for
    /// "the app's own group": once `keychain-access-groups` is declared, the default is the *first*
    /// entry in that list — here the shared, widget-readable one. Callers that care must be explicit.
    let accessGroup: String?
    /// Named `accessibleClass`, not `accessibility`: `accessibility(for:)` below is a method on the
    /// same type, and the two bare reads of this property sit in `Any`-typed dictionary contexts
    /// where an unapplied reference to that method is also convertible. Not worth finding out how
    /// the solver ranks them.
    private let accessibleClass: CFString

    /// - Parameter accessibility: the `kSecAttrAccessible` class for items written by this store.
    ///   `AfterFirstUnlock` is the right default for anything the background refresh needs: the
    ///   system default (`WhenUnlocked`) makes items unreadable whenever the screen is locked, which
    ///   is exactly when the audio keep-alive polls. Use `...ThisDeviceOnly` for secrets that must
    ///   not ride an encrypted backup onto a second device.
    init(
        service: String,
        accessGroup: String? = nil,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibleClass = accessibility
    }

    func set(_ value: String, for key: KeychainKey) throws {
        if let _ = try get(key) {
            try update(value, for: key)
        } else {
            try add(value, for: key)
        }
    }

    func get(_ key: KeychainKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw KeychainError.unhandledStatus(status) }

        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return string
    }

    func delete(_ key: KeychainKey) throws {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// Reads back the stored `kSecAttrAccessible` class, or nil when the item does not exist.
    /// Exists so tests can pin the accessibility contract: a wrong class is invisible in normal use
    /// and only surfaces as background refresh silently failing after a reboot, until the user next
    /// unlocks the device and opens the app.
    func accessibility(for key: KeychainKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw KeychainError.unhandledStatus(status) }

        guard let attributes = result as? [String: Any] else { throw KeychainError.unexpectedData }
        return attributes[kSecAttrAccessible as String] as? String
    }

    private func add(_ value: String, for key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibleClass
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { throw KeychainError.unhandledStatus(status) }
    }

    private func update(_ value: String, for key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let query = baseQuery(for: key)
        // Also set accessibility on update so items saved by a previous build (with the default
        // WhenUnlocked class) are upgraded in place. The launch-time migrate(to:) re-set()s the
        // shared copy on the first unlocked launch, so existing installs self-heal without the
        // user re-entering anything.
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibleClass,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status != errSecSuccess { throw KeychainError.unhandledStatus(status) }
    }

    private func baseQuery(for key: KeychainKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Move the Nightscout credentials from this store into `destination`. Used once at launch to
    /// seed the shared access group from the app's legacy default-group location so the widget
    /// extension can read them.
    ///
    /// Why this moves rather than copies: `get` on a store with no explicit access group issues a
    /// `SecItemCopyMatching` with `kSecMatchLimitOne` and no `kSecAttrAccessGroup`, which searches
    /// *every* group the app belongs to. Once a legacy item and a shared-group item exist for the
    /// same service+account, which of the two that query returns is unspecified — so a copy-only
    /// migration running on every cold launch can resurrect a stale token over the one the user
    /// just typed into Settings, permanently and non-deterministically. Removing the source ends
    /// the ambiguity; leaving it there makes the ambiguity permanent.
    ///
    /// The source is only removed when it is unambiguously addressable: an explicit access group,
    /// different from the destination's. A `SecItemDelete` on a nil-access-group query spans every
    /// group the app belongs to and would take the freshly written destination copy with it.
    func migrate(to destination: KeychainStore) throws {
        let sourceIsDistinct = accessGroup != nil && accessGroup != destination.accessGroup
        for key in KeychainKey.credentials {
            guard let value = try get(key) else { continue }
            // Never clobber a value the destination already holds. The legacy item is very often the
            // STALER of the two — the old copy-only migration never removed it, so a user who has
            // since rotated their token in Settings has a live shared-group value and a dead
            // app-private one. Overwriting produces a silent 401, and `credentialsInvalid`
            // suppresses the Connection Lost alarm, so the only signal is a banner inside an app
            // that has stopped following.
            if try destination.get(key) == nil {
                try destination.set(value, for: key)
            }
            if sourceIsDistinct { try delete(key) }
        }
    }
}

enum KeychainError: Error {
    case unhandledStatus(OSStatus)
    case unexpectedData
    case encodingFailed
}
