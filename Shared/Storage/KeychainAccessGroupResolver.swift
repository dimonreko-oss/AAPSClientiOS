import Foundation
import os
import Security

/// Works out, at runtime, which keychain access groups this process is actually allowed to name.
///
/// Why this is not two string literals: the entitlements declare the group as
/// `$(AppIdentifierPrefix)com.nightaps.aapsclientios.shared`, and the build expands
/// `$(AppIdentifierPrefix)` from whichever team signed it. A literal team prefix therefore matches
/// on exactly one contributor's machine; on any other signing team — or on an unsigned CI simulator
/// runner — the group the code *requests* and the group the entitlement *grants* differ and every
/// `SecItem*` call comes back `errSecMissingEntitlement` (-34018). Nothing crashes, because every
/// call site here is `try?`/`do-catch`: the app just quietly stores no credentials and no pairing.
///
/// How it is worked out: add a throwaway item with no `kSecAttrAccessGroup`, read its attributes
/// back, and take the group iOS filed it under. That is the process's default group — the *first*
/// entry of `keychain-access-groups`, or the implicit `application-identifier` group when the array
/// is absent — so it is a group this process is granted *by construction*, which is why it is used
/// verbatim rather than reassembled from a prefix and a hardcoded bundle id. Public API only, on
/// purpose: `SecTaskCopyValueForEntitlement` would answer the same question more directly but is
/// not public on iOS and is a needless App Store review risk.
///
/// This compiles into the widget extension too, which declares only the shared group; its default
/// group is that same shared group, so the probe yields the same answer there.
enum KeychainAccessGroupResolver {
    /// This repo's own suffixes. Used only to *recognise* the shape of a probed group so the team
    /// prefix can be split off it — never to build the shared group's name, because a fork or a
    /// re-signed install (AltStore & co. rewrite the bundle id and the keychain group) has different
    /// ones and a name nothing grants is -34018 on every call, i.e. the bug this type removes.
    private static let sharedSuffix = "com.nightaps.aapsclientios.shared"
    private static let appPrivateSuffix = "com.nightaps.aapsclientios"
    /// What the entitlements append to the application-identifier group to name the shared one.
    private static let sharedGroupSuffix = ".shared"

    /// Service used by nothing but the probe item, so a probe stranded by a kill between add and
    /// delete can never be confused with real data (`org.diy.aapsclient`, `clientcontrol.pairing`)
    /// nor be picked up by any query this app makes. Internal so a test can assert it is cleaned up.
    static let probeService = "com.nightaps.aapsclientios.access-group-probe"

    /// Shared, widget-readable group, or nil when the probe could not run — see `resolve` for why
    /// nil (unscoped) is the right degraded answer and a guessed name is not.
    static var sharedGroup: String? { resolved.shared }

    /// The process's own `application-identifier` group, or nil under the same condition as
    /// `sharedGroup`. Only App-target code reads this; in the widget it would name the extension's
    /// own group, which is correct for that process and used by nothing.
    static var appPrivateGroup: String? { resolved.appPrivate }

    /// Internal rather than private so `resolve` can be exercised on signing configurations this
    /// machine cannot produce.
    struct Groups: Sendable, Equatable {
        let shared: String?
        let appPrivate: String?

        static let unscoped = Groups(shared: nil, appPrivate: nil)
    }

    private static let cache = OSAllocatedUnfairLock<Groups?>(initialState: nil)

    /// Resolved once per process; every later call is a lock acquire and a read, because this sits
    /// behind every keychain access including the ones on the background refresh path.
    ///
    /// The probe runs *inside* the lock so two queues racing on first use produce one probe item,
    /// not two: the loser waits and then reads the cached answer. It cannot deadlock — the probe
    /// calls `SecItem*` and nothing else, and never re-enters this type. `OSAllocatedUnfairLock`
    /// rather than a second lock flavour because `BackgroundScheduler` already uses it (iOS 16+).
    ///
    /// Only a *success* is cached. A failure means the keychain was unusable right now, and the
    /// conditions that cause it clear inside the same process: this app declares `fetch`/`audio`/
    /// `processing` background modes and two BGTask identifiers, so iOS launches it after a reboot
    /// before the device's first unlock, where even an `AfterFirstUnlock` write is refused — and
    /// that same process stays resident once the user unlocks and foregrounds it. Pinning nil would
    /// hold the whole session on unscoped stores, and the first `pair()` in that session would file
    /// the 32-byte HMAC secret into the shared, widget-readable group, where `migrateLocked` then
    /// leaves it forever. Retrying costs one failing `SecItemAdd` per keychain call, in exactly the
    /// window where the caller's real keychain work was already failing.
    private static var resolved: Groups {
        cache.withLock { (cached: inout Groups?) -> Groups in
            if let cached { return cached }
            let probed = resolve(
                defaultGroup: probeDefaultAccessGroup(),
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
            if probed.shared != nil { cached = probed }
            return probed
        }
    }

    /// Turns the probed default access group into the two group names this app uses.
    ///
    /// Pure and internal so the rules can be tested against signing configurations that cannot be
    /// reproduced on any one machine (another team, a renamed bundle id, an unsigned build).
    ///
    /// A nil result makes both groups nil and therefore every store unscoped, which is the better
    /// of the two wrong answers available: an unscoped query still searches every group the process
    /// belongs to and finds the existing items, whereas a *guessed* group name matches nothing and
    /// turns every call into -34018. The cost is that an unscoped write lands in the process's
    /// default group, so a *newly added* pairing blob would sit in the shared, widget-readable group
    /// rather than the app-private one — the same degradation `ClientPairingStore.writeLocked`
    /// already falls back to, and it keeps the pairing rather than losing it.
    static func resolve(defaultGroup: String?, bundleIdentifier: String?) -> Groups {
        guard let defaultGroup, !defaultGroup.isEmpty,
              // Not a group this app can file its own items into, and a keychain query can
              // legitimately hand it back. Unscoped is the safe answer.
              defaultGroup != "com.apple.token"
        else { return .unscoped }

        // The probed group is granted by construction — iOS has just filed an item into it — so it
        // is named verbatim. The app-private group is `<prefix><application-identifier>`, i.e. the
        // *running* bundle id, which is not necessarily this repo's: a contributor signing with
        // their own team usually has to rename `PRODUCT_BUNDLE_IDENTIFIER`, because automatic
        // signing cannot register an App ID already owned by someone else.
        //
        // The prefix is whatever sits in front of a suffix we recognise, most specific first: a
        // fork renames the bundle id *and* the entitlement; a contributor who renames only
        // `PRODUCT_BUNDLE_IDENTIFIER` keeps this repo's literal suffix in the entitlement.
        // An *empty* prefix is a legitimate result — an unsigned simulator build expands
        // `$(AppIdentifierPrefix)` to nothing and the group is the bare bundle id.
        let bundleId = bundleIdentifier ?? appPrivateSuffix
        let known = [bundleId + sharedGroupSuffix, bundleId, sharedSuffix, appPrivateSuffix]
        for suffix in known where defaultGroup.hasSuffix(suffix) {
            let prefix = String(defaultGroup.dropLast(suffix.count))
            guard prefix.isEmpty || prefix.hasSuffix(".") else { continue }
            return Groups(shared: defaultGroup, appPrivate: prefix + bundleId)
        }

        // A shape none of the rules above recognise. Drop the suffix the entitlement appends, if it
        // is there: that is the application-identifier group for every layout this project uses. If
        // it is not there the two groups coincide, which `KeychainStore.migrate` reads as "source
        // not distinct" and downgrades to a copy — the safe direction — and which
        // `ClientPairingStore.purgeSharedGroupCopyLocked` already handles.
        let appPrivate = defaultGroup.hasSuffix(sharedGroupSuffix)
            ? String(defaultGroup.dropLast(sharedGroupSuffix.count))
            : defaultGroup
        return Groups(shared: defaultGroup, appPrivate: appPrivate)
    }

    /// The access group iOS files an item under when the caller names none, or nil when the probe
    /// could not be written or read (no usable keychain in this context — e.g. a pre-first-unlock
    /// launch, where even an `AfterFirstUnlock` write is refused).
    private static func probeDefaultAccessGroup() -> String? {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            // Fresh every time, so the add can never collide with a leftover from a previous run.
            kSecAttrAccount as String: UUID().uuidString,
        ]
        // Cleaned up on every path out of here, including the ones where the read fails: the item
        // holds nothing worth keeping and a leaked one would outlive even app deletion in the
        // user's keychain. Deleted by SERVICE rather than by account, so the same call also sweeps
        // items stranded by an earlier run that was killed between the add and the delete — routine
        // for the widget extension, which gets jetsammed mid-refresh, and nothing else would ever
        // remove them. Nothing but this probe uses the service, so the sweep cannot touch real data;
        // the one cost is that an app and a widget probing in the same millisecond can sweep each
        // other's live item, and that process then resolves nil — which is not cached, so the next
        // keychain call retries.
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
            ] as CFDictionary)
        }

        var add = identity
        add[kSecValueData as String] = Data("probe".utf8)
        // AfterFirstUnlock like everything else this app writes: with the system default
        // (WhenUnlocked) the probe would fail during a locked-screen background refresh, which is
        // when the resolved group is most needed.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }

        var read = identity
        read[kSecReturnAttributes as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }
}
