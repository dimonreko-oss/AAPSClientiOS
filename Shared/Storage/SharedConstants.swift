import Foundation
import Security

enum SharedConstants {
    static let appGroup = "group.com.nightaps.aapsclientios"
    /// The shared keychain access group, declared by both the app and the widget extension.
    ///
    /// Resolved at runtime instead of hardcoded: the team prefix in front of the suffix is whatever
    /// signed this build, and a literal one only works for the contributor whose team it is. What
    /// comes back is the group iOS actually files this process's unscoped items into, named
    /// verbatim — see `KeychainAccessGroupResolver`. nil means no group name could be established
    /// and callers should go unscoped rather than name a group iOS never granted.
    static var keychainAccessGroup: String? { KeychainAccessGroupResolver.sharedGroup }
    /// The app's own `application-identifier` keychain group. iOS always appends the
    /// application-identifier entitlement to a process's keychain access group list, so this is
    /// available without declaring anything — and, unlike `keychainAccessGroup`, it is *not* in
    /// `Widget/AAPSWidget.entitlements`, so items written here are unreachable from the extension.
    /// Same runtime resolution, from the same single probe, so the two can never disagree on prefix,
    /// and built from the *running* bundle id rather than this repo's literal one — a contributor
    /// signing with their own team normally has to rename `PRODUCT_BUNDLE_IDENTIFIER`.
    static var appPrivateKeychainAccessGroup: String? { KeychainAccessGroupResolver.appPrivateGroup }
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
    /// with a stale one. (If the group could not be resolved at all this falls back to exactly that
    /// ambiguous unscoped lookup — `migrate` then refuses to delete the source, so it is copy-only
    /// and cannot strand anything.)
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
    ///
    /// `ThisDeviceOnly` holds unconditionally. The access group does not: if the group could not be
    /// resolved this store is unscoped, so the blob lands in the process's default (shared) group —
    /// the same degradation `ClientPairingStore.writeLocked` already falls back to when the
    /// app-private group is not usable, and a pairing an extension could read beats no pairing.
    static func pairingKeychain(service: String) -> KeychainStore {
        KeychainStore(
            service: service,
            accessGroup: appPrivateKeychainAccessGroup,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }
}
