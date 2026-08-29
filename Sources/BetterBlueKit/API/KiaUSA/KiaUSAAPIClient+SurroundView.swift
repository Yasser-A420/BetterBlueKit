//
//  KiaUSAAPIClient+SurroundView.swift
//  BetterBlueKit
//
//  Kia US "360 View".
//
//  Kia brands this feature "360 View", not "Surround View Monitor", and
//  files its endpoints under `lbs` (location-based services) rather than
//  anything named after cameras. That is why every sweep of the
//  open-source ecosystem for "surround"/"svm" came up empty on the Kia
//  side: nothing public mentions it, and the paths spell the module
//  neither way.
//
//  FOUR ENDPOINTS, none of them documented anywhere:
//
//    lbs/svm/req     — takes a new capture, body `{}`. Returns as soon as
//                      the request is accepted; the vehicle then wakes its
//                      cameras, shoots, and uploads over a minute or two.
//    lbs/svm/inquire — lists the captures the server holds, body `{}`.
//                      Metadata ONLY: `svmId`, `imageViewed`, `status`
//                      and `location.{coord,head,speed,syncDate}`.
//    lbs/svm/info    — one capture's imagery, body `{svmId}`. The base64
//                      lands in `payload.svmInfos[0].image` — note
//                      `image`, not Hyundai's `svmImage`.
//    lbs/svm/dsi     — deletes captures, body `{svmIds: […]}`. Not used
//                      here; recorded because it pins the verb family.
//
//  So Kia is a THREE-CALL read model where Hyundai needs two: a fetch is
//  one `inquire` plus one `info` per capture, merged before parsing.
//
//  WHERE THE READ ENDPOINTS CAME FROM: the Kia US owners web portal
//  (owners.kia.com, an Adobe AEM/Angular site) still ships the compiled
//  code for its "360 VIEW GALLERY" screen, and three paths appear there
//  in cleartext, in
//  `/etc.clientlibs/owners/designs/owners/angularJS/locations/clientlib.min.js`:
//
//      f.prototype.getSvmInquire=function(a,b){return this._globalService
//        .callApigwServlet(b,a,"POST","/lbs/svm/inquire","postLoginVehicle")…
//      f.prototype.getSvmInfo=function(a,b){…"POST","/lbs/svm/info"…
//      g.prototype.deleteSvm=…{svmIds:this.svmIdsDeleteList}…"POST","/lbs/svm/dsi"…
//
//  The portal reaches them through its own AEM proxy servlet, passing the
//  backend path in an `apiURL` header; a native client calls
//  `https://api.owners.kia.com/apigw/v1/<path>` directly, which is the
//  same base and grammar this client already uses successfully for
//  `cmm/gvi` and `prof/authUser`.
//
//  WHERE THE TRIGGER CAME FROM: probing, because nothing was left to
//  read. The portal's two trigger controls (a "TAKE PIC" span calling
//  `triggrSvmRequest()` and a "TAKE 360 IMAGE" tile calling
//  `initiateSvmRequest()`) survive only inside HTML-comment blocks with
//  no function bodies anywhere in the bundle; Kia's iOS app pins TLS
//  (verified — it aborts the handshake against a proxy CA); and the
//  Android app is DexGuard-obfuscated behind native RASP that
//  self-destructs on a re-signed APK or an emulator.
//
//  So the verb was found empirically, against calibrated controls: of
//  fourteen candidates, thirteen answered errorCode 9000 — identical to a
//  deliberately bogus path — and only `req` answered errorCode 0, the
//  same as a real path handed a body it cannot use. That alone was NOT
//  proof (those two cases look identical); what confirmed it was a real
//  capture landing on the vehicle a minute after the call. `bbcli` menu
//  15 is the probe, menu 16 re-runs the confirmation.
//
//  Because 9000 is what this API answers for a path it cannot route, the
//  trigger asserts `errorCode == 0` rather than trusting
//  `checkForKiaErrors`, which only recognises a handful of codes. The
//  fetch paths get that backstop for free — they fail on the missing
//  payload — but the trigger parses nothing, so a refusal would
//  otherwise read as an accepted request.
//
//  Kia force-disables this whole feature in its own portal, with a comma
//  operator that reads the capability flag and throws the answer away:
//
//      b.SvmFaturSupported=(a.vehicleFeature.locationFeature.surroundView,!1)
//
//  That same portal code independently corroborates the capability flag
//  this file probes: it reads
//  `vehicleFeature.locationFeature.surroundView` (twice, including
//  `b.visibility.supportsSvm=O.surroundView`) and never mentions the
//  `remoteFeature.surroundViewMonitor` decoy.
//

import Foundation

extension KiaUSAAPIClient {

    /// The most captures to pull imagery for in one fetch.
    ///
    /// Kia's own documentation caps the feature at five captures a day
    /// with ten retained, and each capture is a multi-megabyte base64
    /// composite fetched by its own request — so this bounds a fetch to
    /// the documented retention rather than trusting the server's count.
    /// Truncation is logged, never silent.
    static let maxSurroundViewCaptures = 10

    // MARK: - APIClientProtocol

    /// Asks the vehicle for a fresh capture.
    ///
    /// `lbs/svm/req` was found by probing, not by reading it anywhere —
    /// every client that speaks this API is pinned (iOS), hardened
    /// (Android), or had the call stripped (the web portal), so there was
    /// nothing left to read. It is the one candidate out of fourteen that
    /// the server routes: thirteen others answered errorCode **9000**
    /// ("System could not process your request"), the same as a
    /// deliberately bogus path, while `req` answered errorCode **0** —
    /// exactly what the real `lbs/svm/info` answers when handed a body it
    /// cannot use. See `bbcli` menu 15 for the probe and menu 16 for the
    /// experiment that confirms a capture actually lands.
    ///
    /// The body is `{}`, matching `inquire`; the vehicle is identified by
    /// the `vinkey` header.
    ///
    /// - Note: unlike Hyundai USA, no "a capture is already pending"
    ///   error code is known here, so a duplicate request is not remapped
    ///   to `.concurrentRequest`. If one turns up in the wild, map it the
    ///   way `HyundaiUSAAPIClient` maps `HT_533`.
    public func requestSurroundViewCapture(for vehicle: Vehicle, authToken: AuthToken) async throws {
        let (data, json, _) = try await performJSONRequest(
            url: "\(apiURL)lbs/svm/req",
            method: .POST,
            headers: authorizedHeaders(authToken: authToken, vehicleKey: vehicle.vehicleKey),
            body: [:],
            requestType: .requestSurroundView,
            vin: vehicle.vin
        )

        try checkForKiaErrors(data: data)

        // `checkForKiaErrors` only throws for the handful of codes it
        // recognises, and unlike the fetch paths this one has no parse
        // step afterwards to trip over a missing payload. So assert
        // SUCCESS rather than the absence of known failures: without
        // this, any unrecognised refusal — including the 9000 the probe
        // used as its "no such path" control — returns as though the
        // vehicle had accepted the request, and the app would sit
        // polling for a capture that was never taken.
        if let status = json["status"] as? [String: Any],
           let errorCode: Int = extractNumber(from: status["errorCode"]),
           errorCode != 0 {
            throw APIError.logError(
                "Kia US 360 View capture refused — \(status)",
                apiName: apiName
            )
        }
    }

    public func fetchSurroundViewCaptures(
        for vehicle: Vehicle,
        authToken: AuthToken
    ) async throws -> [SurroundViewCapture] {
        // Sort before truncating: nothing documents the order `inquire`
        // answers in, and taking the "first" ten of an oldest-first list
        // would silently fetch the wrong decade of history. The stamps are
        // fixed-width `yyyyMMddHHmmss`, so a string sort IS a date sort.
        var entries = try await fetchSurroundViewIndex(for: vehicle, authToken: authToken)
            .sorted { syncStamp(of: $0) > syncStamp(of: $1) }

        if entries.count > Self.maxSurroundViewCaptures {
            BBLogger.debug(
                .api,
                "KiaUSA: 360 View returned \(entries.count) captures, fetching the newest "
                    + "\(Self.maxSurroundViewCaptures)"
            )
            entries = Array(entries.prefix(Self.maxSurroundViewCaptures))
        }

        var captures: [SurroundViewCapture] = []
        var firstFailure: Error?

        for entry in entries {
            guard let svmId = entry["svmId"], !(svmId is NSNull) else {
                BBLogger.warning(.api, "KiaUSA: skipping 360 View entry without an svmId")
                continue
            }

            do {
                let image = try await fetchSurroundViewImage(
                    svmId: svmId,
                    for: vehicle,
                    authToken: authToken
                )

                // Merge the imagery back into its metadata entry: `inquire`
                // owns the timestamp and coordinates, `info` owns only the
                // image, and the shared parser reads one dictionary.
                var merged = entry
                merged["image"] = image

                if let capture = SurroundViewCaptureParser.capture(
                    from: merged,
                    vin: vehicle.vin,
                    shape: Self.surroundViewShape,
                    apiName: apiName
                ) {
                    captures.append(capture)
                }
            } catch let error as APIError where Self.isAuthFailure(error) {
                // Bubble auth failures up immediately — BBAccount knows how
                // to re-authenticate and retry, and re-trying the remaining
                // ids against a dead session just burns requests. Same rule
                // `triggerRealTimeStatusRefresh` follows for `rems/rvs`.
                throw error
            } catch {
                // One bad image must not cost the user the rest of the
                // history: a single expired or half-uploaded id is
                // survivable where a whole failed response is not. Logged
                // at warning, not debug — a capture silently missing from
                // the history is exactly the kind of thing that otherwise
                // gets diagnosed as "the feature doesn't work".
                BBLogger.warning(.api, "KiaUSA: 360 View image \(svmId) could not be fetched: \(error)")
                firstFailure = firstFailure ?? error
            }
        }

        // "The gallery is empty" and "nothing could be fetched" must stay
        // distinguishable. Returning [] for the second renders as "No
        // Captures Yet" over a full gallery, and hides the one thing a
        // report would need — which matters most while the endpoints are
        // still unverified against a live account, since a response that
        // nests the image somewhere other than `payload.svmInfos[0].image`
        // would otherwise look exactly like a car that has never taken one.
        if captures.isEmpty, let firstFailure {
            throw firstFailure
        }

        return captures.sorted {
            ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast)
        }
    }

    /// Whether an error means "the session is dead", the one class the
    /// per-image loop must not swallow. Mirrors the errors
    /// `BBAccount.shouldReauthenticate` acts on.
    private static func isAuthFailure(_ error: APIError) -> Bool {
        error.errorType == .invalidCredentials || error.errorType == .invalidVehicleSession
    }

    // MARK: - Requests

    /// `lbs/svm/inquire` — the capture list, without imagery. The order is
    /// not documented, so callers sort rather than trusting it.
    private func fetchSurroundViewIndex(
        for vehicle: Vehicle,
        authToken: AuthToken
    ) async throws -> [[String: Any]] {
        // The vehicle is identified by the `vinkey` header, exactly as it
        // is for `cmm/gvi`; the body is genuinely empty (the portal sends
        // `{}`).
        let (data, json, _) = try await performJSONRequest(
            url: "\(apiURL)lbs/svm/inquire",
            method: .POST,
            headers: authorizedHeaders(authToken: authToken, vehicleKey: vehicle.vehicleKey),
            body: [:],
            requestType: .fetchSurroundView,
            vin: vehicle.vin
        )

        try checkForKiaErrors(data: data)

        return try surroundViewEntries(in: json)
    }

    /// Walks the Kia envelope down to the array of captures.
    ///
    /// A missing `payload` is a malformed response and throws; a payload
    /// without `svmInfos` is an account that has simply never taken a
    /// capture, and answers empty.
    private func surroundViewEntries(in json: [String: Any]) throws -> [[String: Any]] {
        guard let payload = json["payload"] as? [String: Any] else {
            throw APIError.logError("Invalid Kia US 360 View response", apiName: apiName)
        }

        return payload["svmInfos"] as? [[String: Any]] ?? []
    }

    /// The capture's `yyyyMMddHHmmss` stamp, or "" when it has none —
    /// which sorts undated captures to the end rather than the front.
    private func syncStamp(of entry: [String: Any]) -> String {
        SurroundViewCaptureParser.value(
            in: entry,
            at: Self.surroundViewShape.timestamp
        ) as? String ?? ""
    }

    /// `lbs/svm/info` — one capture's base64 composite.
    ///
    /// `svmId` is passed back exactly as `inquire` reported it: the portal
    /// echoes the value unchanged (`var d={svmId:a.svmId}`), and coercing
    /// it to a String or an Int here would risk sending a type the server
    /// rejects.
    private func fetchSurroundViewImage(
        svmId: Any,
        for vehicle: Vehicle,
        authToken: AuthToken
    ) async throws -> String {
        let (data, json, _) = try await performJSONRequest(
            url: "\(apiURL)lbs/svm/info",
            method: .POST,
            headers: authorizedHeaders(authToken: authToken, vehicleKey: vehicle.vehicleKey),
            body: ["svmId": svmId],
            requestType: .fetchSurroundView,
            vin: vehicle.vin
        )

        try checkForKiaErrors(data: data)

        guard let payload = json["payload"] as? [String: Any],
              let infos = payload["svmInfos"] as? [[String: Any]],
              let image = infos.first?["image"] as? String else {
            throw APIError.logError("Kia US 360 View response carried no image", apiName: apiName)
        }

        return image
    }

    // MARK: - Parsing

    /// Where Kia puts each field, relative to the merged
    /// `inquire` entry + `info` image.
    ///
    /// Kia's envelope shares nothing with Hyundai's but the pixels: the
    /// image key is `image`, the fix hangs off `location` rather than
    /// `gpsDetail`, and the stamp is `location.syncDate.utc` — the same
    /// bare `yyyyMMddHHmmss` string every region uses, just one level
    /// deeper. `imageSize` keeps its default key so a payload that does
    /// carry the strip descriptor is tiled; when it is absent — which is
    /// every Kia response, since the portal never reads one either —
    /// `SurroundViewDecoder` reconstructs the geometry from the strip's
    /// own SOF header. A live Carnival capture measures 4472×720, the
    /// same layout Hyundai states outright, so the five camera views come
    /// out correctly without this file hardcoding a single dimension.
    ///
    /// Heading sits at `location.head`, beside the fix rather than inside
    /// it — confirmed on a live capture, where two entries from the same
    /// account reported 0 and 67. The portal never reads it, so it was
    /// left unmapped until a real response showed where it lives.
    ///
    /// The door/trunk/mirror flags stay unmapped, and that is now a
    /// finding rather than caution: a real `inquire` entry carries only
    /// `svmId`, `imageViewed`, `status` and `location.{coord,head,speed,
    /// syncDate}`. Kia simply does not report door state with a capture
    /// the way Hyundai does. They surface as nil, which the UI already
    /// treats as "not reported" — distinct from "closed".
    static let surroundViewShape = SurroundViewCaptureParser.EntryShape(
        image: [["image"]],
        timestamp: [["location", "syncDate", "utc"]],
        latitude: [["location", "coord", "lat"]],
        longitude: [["location", "coord", "lon"]],
        heading: [["location", "head"]],
        doors: [],
        trunkOpen: [],
        sideMirrorOpen: []
    )

    /// Parses a saved `lbs/svm/inquire` response merged with its imagery.
    /// Package-visible so `bbcli` can exercise it against a captured
    /// payload without a vehicle in the loop.
    package func parseKiaSurroundViewResponse(
        _ data: Data,
        for vehicle: Vehicle
    ) throws -> [SurroundViewCapture] {
        try checkForKiaErrors(data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.logError("Invalid Kia US 360 View response", apiName: apiName)
        }
        let infos = try surroundViewEntries(in: json)

        return SurroundViewCaptureParser.captures(
            from: infos,
            vin: vehicle.vin,
            shape: Self.surroundViewShape,
            apiName: apiName
        )
    }

    // MARK: - Trigger probe

    /// What one candidate trigger path answered, raw.
    ///
    /// Deliberately unparsed. `checkForKiaErrors` ignores codes it doesn't
    /// recognise, so interpreting a probe's answer would throw away the
    /// very thing that distinguishes "this path does not exist" from
    /// "this path exists and I sent it the wrong body" — which is the
    /// only signal a probe has.
    public struct SurroundViewProbeResult: Sendable {
        public let verb: String
        public let httpStatus: Int?
        /// Kia's own `status.errorCode`. This is the discriminator — but
        /// only ever RELATIVE to a control run in the same session.
        ///
        /// Measured on a live account: a real verb (`inquire`) answers
        /// `0`, and a verb that does not exist (`zzzbogus`) answers
        /// **9000** — "System could not process your request". So the
        /// question to ask of a candidate is not "did it error" (they all
        /// do) but "did it error DIFFERENTLY from the known-bad control".
        ///
        /// An earlier version of this probe flagged any answer carrying a
        /// `status` block as a hit. Every answer carries one, including
        /// the known-bad control, so it reported a false positive on the
        /// first candidate. Never judge a probe answer in isolation.
        public let errorCode: Int?
        /// The server's own `status` block, verbatim.
        public let statusBlock: String?
        public let body: String
    }

    /// Sends one candidate verb under `lbs/svm/` and reports what came
    /// back, without interpreting it.
    ///
    /// Diagnostic only — nothing in the app calls this. Kia's capture
    /// trigger is not documented anywhere (see the file header), and
    /// every client platform that speaks it is pinned or stripped, so the
    /// only remaining way to find it is to ask the server about a short,
    /// reasoned list of candidates and read the answers. Run it through
    /// `bbcli`, which brackets the candidates with a known-good and a
    /// known-bad control so the answers are calibrated rather than
    /// guessed at.
    ///
    /// - Warning: a candidate that IS the trigger will actually take a
    ///   capture. Kia caps the feature at five a day, so keep candidate
    ///   lists short and stop at the first genuine hit.
    public func probeSurroundViewVerb(
        _ verb: String,
        for vehicle: Vehicle,
        authToken: AuthToken,
        body: [String: Any] = [:]
    ) async -> SurroundViewProbeResult {
        do {
            let (data, json, response) = try await performJSONRequest(
                url: "\(apiURL)lbs/svm/\(verb)",
                method: .POST,
                headers: authorizedHeaders(authToken: authToken, vehicleKey: vehicle.vehicleKey),
                body: body,
                requestType: .requestSurroundView,
                vin: vehicle.vin
            )

            let status = json["status"] as? [String: Any]
            return SurroundViewProbeResult(
                verb: verb,
                httpStatus: response.statusCode,
                errorCode: extractNumber(from: status?["errorCode"]),
                statusBlock: status.map { "\($0)" },
                body: String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            )
        } catch {
            // `validateHTTPResponse` folds the response body into the
            // message, so the raw answer survives even on a non-2xx.
            let message = "\(error)"
            return SurroundViewProbeResult(
                verb: verb,
                httpStatus: nil,
                errorCode: Self.errorCode(inErrorMessage: message),
                statusBlock: nil,
                body: message
            )
        }
    }

    /// Digs Kia's numeric error code out of a thrown error's message, so a
    /// candidate that failed at the HTTP layer is still comparable to the
    /// controls rather than dropping out of the calibration.
    private static func errorCode(inErrorMessage message: String) -> Int? {
        guard let range = message.range(of: #"API Error (\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(message[range].dropFirst("API Error ".count))
    }

    // MARK: - Capability probe

    /// Asks `cmm/gvi` for the vehicle's feature tree.
    ///
    /// The production status call sends `vehicleFeature: "0"`, which
    /// suppresses this block entirely. Sending `"1"` is what a sibling
    /// project (`ha_kia_hyundai_USA`) does to read
    /// `vehicleConfig.vehicleFeature.remoteFeature.*`, and the Kia owners
    /// portal reads `locationFeature.surroundView` out of the same tree.
    ///
    /// Diagnostic only — nothing in the app calls this. Reach it through
    /// `bbcli`, which prints the raw tree so an unexpected shape is
    /// visible rather than being flattened into a bool.
    ///
    /// - Important: only `vehicleFeature` is changed. `vehicleStatus` must
    ///   stay `"1"` or the server answers 9001 ("Incorrect request payload
    ///   format") — and `checkForKiaErrors` does not recognise 9001, so
    ///   that failure would surface as a confusing parse error.
    public func fetchVehicleFeatureTree(
        for vehicle: Vehicle,
        authToken: AuthToken
    ) async throws -> [String: Any] {
        let body: [String: Any] = [
            "vehicleConfigReq": [
                "airTempRange": "0",
                "maintenance": "0",
                "seatHeatCoolOption": "0",
                "vehicle": "1",
                "vehicleFeature": "1"
            ],
            "vehicleInfoReq": [
                "drivingActivty": "0",
                "dtc": "0",
                "enrollment": "0",
                "functionalCards": "0",
                "location": "0",
                "vehicleStatus": "1",
                "weather": "0"
            ],
            "vinKey": [vehicle.vehicleKey ?? ""]
        ]

        let (data, json, _) = try await performJSONRequest(
            url: "\(apiURL)cmm/gvi",
            method: .POST,
            headers: authorizedHeaders(authToken: authToken, vehicleKey: vehicle.vehicleKey),
            body: body,
            requestType: .fetchVehicleStatus,
            vin: vehicle.vin
        )

        try checkForKiaErrors(data: data)

        // Same nesting the status parser walks: the config hangs off the
        // per-vehicle entry in `vehicleInfoList`, not off `payload`.
        //
        // Surface the server's own status block when the tree is absent:
        // an unrecognised error code would otherwise reach the caller as
        // an empty dictionary, which reads as "no features" rather than
        // "the request was refused".
        guard let payload = json["payload"] as? [String: Any],
              let vehicleInfoList = payload["vehicleInfoList"] as? [[String: Any]],
              let vehicleInfo = vehicleInfoList.first(where: { $0["vinKey"] as? String == vehicle.vehicleKey })
              ?? vehicleInfoList.first,
              let config = vehicleInfo["vehicleConfig"] as? [String: Any],
              let features = config["vehicleFeature"] as? [String: Any] else {
            let status = (json["status"] as? [String: Any]).map { "\($0)" } ?? "no status block"
            throw APIError.logError(
                "Kia gvi returned no vehicleConfig.vehicleFeature — \(status)",
                apiName: apiName
            )
        }

        return features
    }

    /// Whether this vehicle advertises 360-view hardware.
    ///
    /// Reads `vehicleFeature.locationFeature.surroundView`, confirmed
    /// against a live Kia US account (a Carnival Hybrid, which
    /// returned `"1"`) and independently corroborated by the owners
    /// portal, which reads the same key path in two places. Kia files it
    /// under `locationFeature` beside `lastMile`, the same way Hyundai
    /// names its endpoint `findMyCarSVM` and Kia files its own endpoints
    /// under `lbs`: all three treat remote cameras as a find-my-car
    /// feature rather than a remote command. Values arrive as the strings
    /// "1" and "0", not booleans.
    ///
    /// - Warning: `remoteFeature.surroundViewMonitor` is a DIFFERENT flag
    ///   and read it is not. The same vehicle reports `surroundView: "1"`
    ///   and `surroundViewMonitor: "0"` in one response, so they cannot
    ///   mean the same thing; the portal never reads the latter either.
    ///   Reading it instead would say "unsupported" for a vehicle whose
    ///   owner uses the feature daily.
    ///
    /// Returns nil when the key is absent, which is NOT the same as false
    /// — it means the flag has moved, and the raw tree should be read
    /// instead.
    public func reportsSurroundView(for vehicle: Vehicle, authToken: AuthToken) async throws -> Bool? {
        let features = try await fetchVehicleFeatureTree(for: vehicle, authToken: authToken)

        guard let location = features["locationFeature"] as? [String: Any],
              let value = location["surroundView"] else {
            return nil
        }

        if let bool = value as? Bool { return bool }
        if let number: Int = extractNumber(from: value) { return number != 0 }
        if let string = value as? String { return ["1", "true", "y", "yes"].contains(string.lowercased()) }
        return nil
    }
}
