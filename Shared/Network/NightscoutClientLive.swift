import Foundation

actor NightscoutClientLive: NightscoutClient {
    private let nsURL: String
    private let accessToken: String
    private let transport: HttpTransport
    private let decoder = JSONDecoder()
    private var jwtToken: String = ""
    /// `exp` from the last successful `authorize()`, so a poll can re-authorize BEFORE the JWT
    /// lapses instead of spending a round trip discovering a 401 it could have predicted.
    private var jwtExpiry: Date?
    /// Renew this far ahead of `exp` — one poll interval of slack is plenty.
    private static let jwtRenewalMargin: TimeInterval = 60

    init(baseURL: URL, accessToken: String, transport: HttpTransport) {
        let urlString = baseURL.absoluteString
        self.nsURL = urlString.hasSuffix("/") ? urlString : "\(urlString)/"
        self.accessToken = accessToken
        self.transport = transport
    }

    func authorize() async throws {
        // The NS access token rides as a PATH SEGMENT here — the endpoint shape is Nightscout's and
        // cannot be changed, and this is the only place the raw token leaves the device. Percent-encode
        // it so a token containing reserved characters cannot reshape the path.
        //
        // NO-LOG INVARIANT: this URL must never be logged or embedded in an error. That is why the
        // unauthenticated authorize request handles its own status codes below and never reaches
        // `httpError` (which does put `request.url?.path` into the message).
        let encodedToken = accessToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? accessToken
        let urlString = "\(nsURL)api/v2/authorization/request/\(encodedToken)"
        guard let url = URL(string: urlString) else { throw NsError.badURL }
        let request = URLRequest(url: url)
        let (data, response) = try await execute(request, authenticated: false)
        if response.statusCode == 401 || response.statusCode == 403 {
            // The token itself was rejected (revoked, or its role changed). Distinct from a flaky
            // network — callers surface this as a credentials problem, not "connection lost".
            jwtToken = ""
            jwtExpiry = nil
            throw NsError.unauthorized
        }
        guard response.statusCode == 200 else {
            throw NsError.server(response.statusCode)
        }
        guard let auth = try? decoder.decode(RemoteAuthResponse.self, from: data),
              !auth.token.isEmpty else {
            throw NsError.decoding("Invalid auth response")
        }
        jwtToken = auth.token
        jwtExpiry = auth.exp > 0 ? Date(timeIntervalSince1970: Double(auth.exp)) : nil
    }

    func fetchEntries(limit: Int) async throws -> [GlucoseReading] {
        let path = "api/v3/entries?sort$desc=date&limit=\(limit)"
        let data = try await get(path)
        return try NsMapping.glucose(from: data)
    }

    func fetchTreatments(since: Date? = nil) async throws -> [Treatment] {
        let pageSize = 100
        var all: [Treatment] = []
        var seen = Set<String>()
        var skip = 0

        for _ in 0..<20 {
            var path = "api/v3/treatments?sort$desc=date&limit=\(pageSize)&skip=\(skip)"
            if let since {
                path += "&srvModified$gte=\(Int64(since.timeIntervalSince1970 * 1000))"
            }
            let data = try await get(path)
            let page = try NsMapping.treatments(from: data)
            if page.isEmpty { break }
            for treatment in page where seen.insert(treatment.id).inserted {
                all.append(treatment)
            }
            if page.count < pageSize { break }
            skip += page.count
        }
        return all
    }

    /// Two-step on purpose.
    ///
    /// `limit=1` was making `NsMapping.loopStatus`'s "newest record carrying an APS result" lookup
    /// unreachable: a master whose loop is stopped uploads pump-only keep-alive records every five
    /// minutes, so the single newest record has no APS block and the whole status — including the
    /// perfectly fresh pump reservoir and battery it *does* carry — came back nil. But a devicestatus
    /// document with `predBGs` is several kilobytes, and this runs on every 30–60 s background tick,
    /// so paging 12 of them unconditionally is a cellular bill nobody agreed to. Widen only when the
    /// cheap read found no APS result; twelve records is one hour of keep-alive.
    func fetchDeviceStatus() async throws -> LoopStatus? {
        let data = try await get("api/v3/devicestatus?sort$desc=date&limit=1")
        if let status = try NsMapping.loopStatus(from: data) { return status }
        let page = try await get("api/v3/devicestatus?sort$desc=date&limit=\(Self.deviceStatusLookback)")
        return try NsMapping.loopStatus(from: page)
    }

    /// One hour of five-minute keep-alive records.
    private static let deviceStatusLookback = 12

    func fetchDeviceStatusHeartbeat() async throws -> Date? {
        // `fields=date` keeps this to a few bytes; a server that ignores the projection just sends
        // the whole document, which the mapper reads identically.
        let data = try await get("api/v3/devicestatus?sort$desc=date&limit=1&fields=date")
        return try NsMapping.deviceStatusHeartbeat(from: data)
    }

    func fetchProfile() async throws -> NsProfile {
        let path = "api/v3/profile?sort$desc=date&limit=1"
        let data = try await get(path)
        return try NsMapping.profile(from: data)
    }

    func fetchProfileStore() async throws -> NsProfileStore {
        let path = "api/v3/profile?sort$desc=date&limit=1"
        let data = try await get(path)
        return try NsMapping.profileStore(from: data)
    }

    func fetchSettings(identifier: String) async throws -> NsSettingsDocument? {
        let path = "api/v3/settings/\(identifier)"
        do {
            let data = try await get(path)
            return try NsMapping.settingsDocument(from: data, identifier: identifier)
        } catch let error as NsHttpStatusError where error.code == 404 {
            // NS APIv3 returns 404 for a settings identifier that was never written. On a freshly
            // paired client the ack slot legitimately does not exist yet, so this is "no document",
            // not a failure — the AAPS SDK special-cases it identically (code 404, values null).
            // Throwing here aborted the very first ack poll on iteration 1 against a healthy master.
            return nil
        }
    }

    func putSettings(identifier: String, document: [String: Any]) async throws {
        let path = "api/v3/settings/\(identifier)"
        let body = try JSONSerialization.data(withJSONObject: document)
        _ = try await put(path, body: body)
    }

    /// HARD delete (`?permanent=true`), never the plain one.
    ///
    /// A bare `DELETE /api/v3/settings/<id>` only SOFT-deletes: NS tombstones the identifier and
    /// every later PUT to that same per-type command slot returns HTTP 410 forever. The one caller
    /// here (`ClientControlPublisher.putRecoveringPoisonedDate`) deletes precisely so it can re-PUT,
    /// so a soft delete would convert the recoverable "Field date cannot be modified" wedge into a
    /// permanent one. The master learned the same lesson twice — `ClientControlReceiver` refuses to
    /// delete inbound command docs at all, and `NSAndroidClient.deleteSettingsPermanent` exists for
    /// exactly this case (`PairingOfferPublisher` is its other user).
    func deleteSettings(identifier: String) async throws {
        let path = "api/v3/settings/\(identifier)?permanent=true"
        do {
            _ = try await delete(path)
        } catch let error as NsHttpStatusError where error.code == 404 || error.code == 410 {
            // Already absent — that is exactly the outcome the caller wanted.
        }
    }

    func searchSettings(limit: Int) async throws -> [NsSettingsDocument] {
        let path = "api/v3/settings?limit=\(limit)"
        let data = try await get(path)
        return try NsMapping.settingsDocuments(from: data)
    }

    func fetchRunningConfigCold() async throws -> NsRunningConfigCold? {
        guard let document = try await fetchSettings(identifier: NightscoutSettingsIdentifier.cold) else { return nil }
        return try NsMapping.runningConfigCold(from: document)
    }

    func fetchRunningConfigHot() async throws -> NsRunningConfigHot? {
        guard let document = try await fetchSettings(identifier: NightscoutSettingsIdentifier.state) else { return nil }
        return try NsMapping.runningConfigHot(from: document)
    }

    /// Paginated entries covering `days` back.
    /// Uses skip-based pagination + server-side date$gt filter (NS v3 ignores date$lt cursors).
    func fetchEntries(sinceDays days: Int) async throws -> [GlucoseReading] {
        let cutoffMs = Int64(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 * 1000)
        let pageSize = 1000
        var all: [GlucoseReading] = []
        var seenDates = Set<Date>()
        var skip = 0
        for _ in 0..<200 {
            let path = "api/v3/entries?sort$desc=date&limit=\(pageSize)&skip=\(skip)&date$gt=\(cutoffMs)"
            let data = try await get(path)
            let page = try NsMapping.glucose(from: data)
            if page.isEmpty { break }
            for entry in page where seenDates.insert(entry.date).inserted {
                all.append(entry)
            }
            skip += page.count
        }
        return all
    }

    func fetchDeviceStatusHistory(since: Date) async throws -> [DeviceStatusEntry] {
        let cutoffMs = Int64(since.timeIntervalSince1970 * 1000)
        let path = "api/v3/devicestatus?sort$desc=date&limit=288&date$gt=\(cutoffMs)"
        let data = try await get(path)
        return try NsMapping.deviceStatusHistory(from: data)
    }

    func fetchTreatmentsHistory(since: Date) async throws -> [Treatment] {
        let cutoffMs = Int64(since.timeIntervalSince1970 * 1000)
        let pageSize = 500
        var all: [Treatment] = []
        var seen = Set<String>()
        var skip = 0
        for _ in 0..<40 {
            let path = "api/v3/treatments?sort$desc=date&limit=\(pageSize)&skip=\(skip)&date$gt=\(cutoffMs)"
            let data = try await get(path)
            let page = try NsMapping.treatments(from: data)
            if page.isEmpty { break }
            for treatment in page where seen.insert(treatment.id).inserted {
                all.append(treatment)
            }
            if page.count < pageSize { break }
            skip += page.count
        }
        return all
    }

    func fetchCareEvents() async throws -> [Treatment] {
        let types = ["Site Change", "Sensor Change", "Sensor Start", "Insulin Change", "Pump Battery Change", "Profile Switch"]
        let inValue = types.joined(separator: "|")
        let encoded = inValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? inValue
        let path = "api/v3/treatments?sort$desc=date&limit=50&eventType$in=\(encoded)"
        let data = try await get(path)
        return try NsMapping.treatments(from: data)
    }

    func postTreatment(_ payload: [String: Any]) async throws {
        let path = "api/v3/treatments"
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await post(path, body: body)
    }

    // MARK: - Private

    private func get(_ path: String) async throws -> Data {
        let urlString = "\(nsURL)\(path)"
        guard let url = URL(string: urlString) else { throw NsError.badURL }
        let request = URLRequest(url: url)
        return try await authenticatedData(request)
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        let urlString = "\(nsURL)\(path)"
        guard let url = URL(string: urlString) else { throw NsError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await authenticatedData(request)
    }

    private func put(_ path: String, body: Data) async throws -> Data {
        let urlString = "\(nsURL)\(path)"
        guard let url = URL(string: urlString) else { throw NsError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await authenticatedData(request)
    }

    private func delete(_ path: String) async throws -> Data {
        let urlString = "\(nsURL)\(path)"
        guard let url = URL(string: urlString) else { throw NsError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        return try await authenticatedData(request)
    }

    private func authenticatedData(_ request: URLRequest) async throws -> Data {
        if jwtToken.isEmpty || jwtIsExpiring() {
            try await authorize()
        }
        let (data, response) = try await execute(request, authenticated: true)
        if response.statusCode == 401 || response.statusCode == 403 {
            try await refreshJWT()
            let (retryData, retryResponse) = try await execute(request, authenticated: true)
            if retryResponse.statusCode >= 400 {
                throw httpError(retryResponse.statusCode, retryData, request)
            }
            return retryData
        }
        if response.statusCode >= 400 {
            throw httpError(response.statusCode, data, request)
        }
        return data
    }

    /// True once the JWT is inside its renewal margin (or already past `exp`). A server that issues
    /// short-lived tokens otherwise guarantees a 401 + retry on every poll.
    private func jwtIsExpiring(now: Date = Date()) -> Bool {
        guard let jwtExpiry else { return false }
        return now.addingTimeInterval(Self.jwtRenewalMargin) >= jwtExpiry
    }

    /// Diagnostic error carrying HTTP status + server body + method/path.
    ///
    /// `request.url?.path` is safe to include ONLY because the one request whose path embeds the
    /// access token — the unauthenticated `authorize()` — handles its own status codes and never
    /// reaches this function. Any future unauthenticated call must keep that property.
    private func httpError(_ code: Int, _ body: Data, _ request: URLRequest) -> Error {
        let bodyText = String(data: body, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
        let method = request.httpMethod ?? "?"
        let path = request.url?.path ?? "?"
        return NsHttpStatusError(code: code, detail: "HTTP \(code) \(method) \(path) — \(bodyText)", body: bodyText)
    }

    private func execute(_ request: URLRequest, authenticated: Bool) async throws -> (Data, HTTPURLResponse) {
        var req = request
        if authenticated {
            req.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await transport.execute(req)
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let error as NsError {
            throw error
        } catch {
            throw NsError.noNetwork
        }
    }

    private func refreshJWT() async throws {
        try await authorize()
    }
}

private struct RemoteAuthResponse: Decodable {
    let token: String
    let iat: Int64
    let exp: Int64
}

/// A non-2xx HTTP answer from Nightscout, typed so callers can branch on the STATUS instead of
/// string-matching a diagnostic message. `NsError` lives in the shared domain layer and is what the
/// UI renders, so this keeps the exact same human-readable text and only adds the code.
struct NsHttpStatusError: LocalizedError, CustomStringConvertible, Equatable {
    let code: Int
    /// "HTTP 400 PUT /api/v3/settings/… — <body prefix>"
    let detail: String
    /// The server body prefix on its own, so a caller can recognise a specific NS rejection.
    let body: String

    var description: String { detail }
    var errorDescription: String? { String(localized: "error.decoding") + ": \(detail)" }

    /// NS APIv3 refuses to change a settings document's `date` after create ("Field date cannot be
    /// modified by the client"). The client-control command slots are latest-wins, so a slot created
    /// with a live timestamp stays wedged until it is deleted and re-created.
    var isImmutableDateRejection: Bool {
        code == 400 && body.range(of: "cannot be modified", options: .caseInsensitive) != nil
    }
}
