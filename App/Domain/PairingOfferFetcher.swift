import Foundation

enum PairingOfferFetcher {
    enum MatchResult: Equatable {
        case success(PairingPayload)
        case ambiguous
        case noMatch
    }

    static let offerIdentifierPrefix = "aaps_clientcontrol_offer_"

    static func match(offers: [PairingOffer], pin: String, now: Date) -> MatchResult {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var matches: [PairingPayload] = []

        for offer in offers {
            if offer.expiresAt > 0, offer.expiresAt < nowMs { continue }
            guard let salt = Data(base64Encoded: offer.kdfSaltB64),
                  let iv = Data(base64Encoded: offer.ivB64),
                  let wrapped = Data(base64Encoded: offer.wrappedB64),
                  let plaintext = ClientControlPairingCrypto.unwrap(ciphertext: wrapped, pin: pin, salt: salt, iv: iv),
                  let payload = try? JSONDecoder().decode(PairingPayload.self, from: plaintext) else {
                continue
            }
            if payload.expiresAt > 0, payload.expiresAt < nowMs { continue }
            guard !payload.masterInstallId.isEmpty, !payload.clientId.isEmpty, !payload.secretHex.isEmpty else { continue }
            matches.append(payload)
        }

        switch matches.count {
        case 0: return .noMatch
        case 1: return .success(matches[0])
        default: return .ambiguous
        }
    }

    /// Re-check at confirm time. `match` filters on expiry at *scan* time, but the master's pairing
    /// window is only `PAIR_TTL_MS` = 2 minutes and the user can sit on the confirm screen for
    /// longer than that. Past `expiresAt` the master has pruned its Pending roster entry, the
    /// receiver logs "pairing window expired" and `markActive` is unreachable — so committing the
    /// secret then produces a client that looks paired and can never be promoted. Mirrors the
    /// second expiry check in AndroidAPS's `PairWithMasterViewModel`.
    static func isExpired(_ payload: PairingPayload, now: Date) -> Bool {
        guard payload.expiresAt > 0 else { return false }
        return payload.expiresAt < Int64(now.timeIntervalSince1970 * 1000)
    }

    /// Seconds left on the pairing window, or nil when the offer carries no expiry. Clamped at zero.
    /// Surfacing this is what makes a stale-PIN failure self-explanatory.
    static func remainingLifetime(_ payload: PairingPayload, now: Date) -> TimeInterval? {
        guard payload.expiresAt > 0 else { return nil }
        let seconds = Double(payload.expiresAt) / 1000 - now.timeIntervalSince1970
        return max(0, seconds)
    }
}
