import Foundation
import Security

enum SharedConstants {
    static let appGroup = "group.com.nightaps.aapsclientios"
    static let keychainAccessGroup = "J6275F9A66.com.nightaps.aapsclientios.shared"
    /// The app's own `application-identifier` keychain group. iOS always appends the
    /// application-identifier entitlement to a process's keychain access group list, so this is
    /// available without declaring anything — and, unlike `keychainAccessGroup`, it is *not* in
    /// `Widget/AAPSWidget.entitlements`, so items written here are unreachable from the extension.
    static let appPrivateKeychainAccessGroup = "J6275F9A66.com.nightaps.aapsclientios"
    static let keychainService = "org.diy.aapsclient"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    /// Credentials store on the shared keychain access group — read/written by both
    /// the app and the widget extension. This is the single source of truth.
    static func credentialKeychain() -> KeychainStore {
        KeychainStore(service: keychainService, accessGroup: keychainAccessGroup)
    }

    /// Pre-widget credentials location. Explicitly scoped to the app's own access group: before the
    /// widget existed the app declared no `keychain-access-groups`, so its default group *was* the
    /// application-identifier one. Naming it makes the lookup deterministic — an unscoped query
    /// searches every group the app belongs to and can just as easily return the current shared
    /// item, which is how a copy-only launch migration ends up overwriting a freshly edited token
    /// with a stale one.
    static func legacyKeychain() -> KeychainStore {
        KeychainStore(service: keychainService, accessGroup: appPrivateKeychainAccessGroup)
    }

    /// Move any pre-widget credentials into `destination`. Self-terminating rather than flag-guarded:
    /// `migrate` removes the source, so the second launch finds nothing to do. A UserDefaults flag
    /// would add a failure mode (flag set, migration actually failed) without removing one.
    static func migrateLegacyCredentials(into destination: KeychainStore) {
        do {
            try legacyKeychain().migrate(to: destination)
        } catch {
            // The application-identifier group is not usable under this build's provisioning
            // profile (`errSecMissingEntitlement`). Fall back to the historical unscoped lookup:
            // ambiguous, and therefore copy-only, but better than stranding the credentials of a
            // pre-widget install behind a group name we guessed wrong.
            try? KeychainStore(service: keychainService).migrate(to: destination)
        }
    }

    /// Store for the client-control pairing blob.
    ///
    /// Two deliberate differences from `credentialKeychain()`:
    /// - **App-private access group.** The blob holds the 32-byte HMAC secret that authenticates
    ///   every remote command. The widget reads only the NS URL and token, so there is no reason
    ///   for the secret to sit in a group an extension can open.
    /// - **`ThisDeviceOnly`.** The pairing is one `(clientId, counter)` pair and the master's replay
    ///   gate is strictly-greater. If the secret rode an encrypted backup onto a second device, both
    ///   devices would sign envelopes as the same client with independent counters and each would
    ///   knock the other out. `AfterFirstUnlock` is still required so the background refresh can
    ///   sign while the screen is locked.
    static func pairingKeychain(service: String) -> KeychainStore {
        KeychainStore(
            service: service,
            accessGroup: appPrivateKeychainAccessGroup,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }
}
