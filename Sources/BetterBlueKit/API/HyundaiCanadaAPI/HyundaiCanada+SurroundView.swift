//
//  HyundaiCanada+SurroundView.swift
//  BetterBlueKit
//
//  Hyundai Canada Surround View Monitor (SVM)
//
//  Two endpoints, same "remote function call" family as `fndmcr`:
//
//    rfc/fndmcrsvm  — tells the vehicle to wake its cameras, shoot, and
//                     upload. Returns immediately; the images land on
//                     Hyundai's servers a few minutes later.
//    rfc/lastmcrsvm — returns the captures the server is holding
//                     (several, newest first), each with its imagery
//                     base64-encoded in `svmImage`.
//

import Foundation

extension HyundaiCanadaAPIClient {

    // MARK: - APIClientProtocol

    public func requestSurroundViewCapture(for vehicle: Vehicle, authToken: AuthToken) async throws {
        _ = try await ensureCloudFlareCookie()
        let authCode = try await fetchCommandAuthCode(authToken: authToken)

        _ = try await performSurroundViewRequest(
            path: "rfc/fndmcrsvm",
            vehicle: vehicle,
            authToken: authToken,
            authCode: authCode,
            requestType: .requestSurroundView
        )
    }

    public func fetchSurroundViewCaptures(
        for vehicle: Vehicle,
        authToken: AuthToken
    ) async throws -> [SurroundViewCapture] {
        _ = try await ensureCloudFlareCookie()
        let authCode = try await fetchCommandAuthCode(authToken: authToken)

        let data = try await performSurroundViewRequest(
            path: "rfc/lastmcrsvm",
            vehicle: vehicle,
            authToken: authToken,
            authCode: authCode,
            requestType: .fetchSurroundView
        )

        return try parseCanadaSurroundViewResponse(data, for: vehicle)
    }

    // MARK: - Request

    /// Sends one SVM call with the native-app identity, falling back
    /// once to this client's own login headers.
    ///
    /// Same rule as `fndmcr`: everything in the "find my car" family
    /// answers `from: SPA` (`locationHeaders`) and rejects `from: CWP`
    /// with errorCode 6459, regardless of which identity the account
    /// logged in with (BetterBlueKit#36). Verified on a live account —
    /// a capture request that 6459'd on the web-portal headers succeeded
    /// first try on these.
    ///
    /// SVM and `fndmcr` are the same remote-function family, so if the
    /// location sweep has already learned this account answers only to
    /// its own login identity, lead with that instead of re-paying the
    /// rejection on every poll of a capture.
    ///
    /// The response is validated inside each attempt on purpose: this
    /// API signals refusal as HTTP 200 with `responseCode: 1` in the
    /// body, so a fallback keyed on transport errors alone would never
    /// fire.
    private func performSurroundViewRequest(
        path: String,
        vehicle: Vehicle,
        authToken: AuthToken,
        authCode: String,
        requestType: HTTPRequestType
    ) async throws -> Data {
        let native = locationHeaders(authToken: authToken, vehicleId: vehicle.regId, pAuth: authCode)
        let account = authorizedHeaders(authToken: authToken, vehicleId: vehicle.regId, pAuth: authCode)
        let ordered = locationStrategy == .findMyCarAccount ? [account, native] : [native, account]

        var firstError: Error?
        for headers in ordered {
            do {
                return try await sendSurroundViewRequest(
                    path: path,
                    vehicle: vehicle,
                    headers: headers,
                    requestType: requestType
                )
            } catch {
                firstError = firstError ?? error
                BBLogger.debug(.api, "HyundaiCanada: \(path) failed, trying the other identity: \(error)")
            }
        }

        // Surface the FIRST failure: the fallback is a guess, so its
        // error is usually less informative than the one from the
        // identity this account actually logs in with.
        throw firstError ?? APIError.logError("Surround view request failed", apiName: apiName)
    }

    private func sendSurroundViewRequest(
        path: String,
        vehicle: Vehicle,
        headers: [String: String],
        requestType: HTTPRequestType
    ) async throws -> Data {
        let (data, _, _) = try await performJSONRequest(
            url: "\(apiBaseURL)/\(path)",
            method: .POST,
            headers: headers,
            body: ["pin": pin],
            requestType: requestType,
            vin: vehicle.vin
        )

        _ = try parseCanadaResponse(data, context: "surround view")
        return data
    }

    // MARK: - Parsing

    package func parseCanadaSurroundViewResponse(
        _ data: Data,
        for vehicle: Vehicle
    ) throws -> [SurroundViewCapture] {
        let json = try parseCanadaResponse(data, context: "surround view")

        guard let result = json["result"] as? [String: Any],
              let locations = result["svmLocations"] as? [[String: Any]] else {
            throw APIError.logError("Invalid Canada surround view response", apiName: apiName)
        }

        let captures = locations.compactMap { parseSurroundViewLocation($0, for: vehicle) }

        // Newest first. The server has been observed returning them in
        // that order already, but nothing documents that guarantee.
        return captures.sorted {
            ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast)
        }
    }

    private func parseSurroundViewLocation(
        _ location: [String: Any],
        for vehicle: Vehicle
    ) -> SurroundViewCapture? {
        guard let encodedImage = location["svmImage"] as? String,
              let imageData = Data(base64Encoded: encodedImage, options: .ignoreUnknownCharacters) else {
            BBLogger.debug(.api, "HyundaiCanada: skipping surround view entry without decodable image")
            return nil
        }

        let frames = SurroundViewDecoder.extractJPEGFrames(from: imageData)
        guard !frames.isEmpty else {
            BBLogger.debug(.api, "HyundaiCanada: surround view entry contained no JPEG frames")
            return nil
        }

        let imageSize = (location["imageSize"] as? [Any])?.compactMap { extractNumber(from: $0) as Int? } ?? []
        let gpsDetail = location["gpsDetail"] as? [String: Any]

        return SurroundViewCapture(
            vin: vehicle.vin,
            capturedAt: parseSurroundViewTimestamp(location["utcTime"] ?? gpsDetail?["time"]),
            location: parseSurroundViewLocationCoordinates(gpsDetail),
            heading: extractNumber(from: gpsDetail?["head"]),
            doorOpen: parseSurroundViewDoors(location["doorOpen"] as? [String: Any]),
            trunkOpen: parseSurroundViewFlag(location["trunkOpen"]),
            sideMirrorOpen: parseSurroundViewFlag(location["sidemirrorOpen"]),
            frames: frames,
            tiles: SurroundViewDecoder.tiles(imageSize: imageSize, frameCount: frames.count)
        )
    }

    /// `utcTime` is a bare `yyyyMMddHHmmss` stamp in UTC, e.g.
    /// "20260826003935". The sibling `offset` field is the vehicle's
    /// local timezone offset and is deliberately ignored — the app
    /// renders the capture time in the user's own timezone.
    private func parseSurroundViewTimestamp(_ value: Any?) -> Date? {
        guard let raw = value as? String, raw.count == 14 else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    /// SVM reports coordinates as flat `coordLat` / `coordLon` fields,
    /// unlike the `coord: { lat, lon }` object the status endpoints use.
    private func parseSurroundViewLocationCoordinates(_ gpsDetail: [String: Any]?) -> VehicleStatus.Location? {
        guard let gpsDetail,
              let latitude: Double = extractNumber(from: gpsDetail["coordLat"]),
              let longitude: Double = extractNumber(from: gpsDetail["coordLon"]) else {
            return nil
        }

        let location = VehicleStatus.Location(latitude: latitude, longitude: longitude)
        return location.hasCoordinates ? location : nil
    }

    /// Reads an open/closed flag that may arrive as a JSON boolean or as
    /// 0/1. This region mixes the two even within one payload — the same
    /// `unit` field is `true` under `dte` and `1` under `distanceToEmpty`
    /// (BetterBlue#98) — so never bet on a bare `as? Bool`.
    /// Returns nil only when the key is absent entirely.
    private func parseSurroundViewFlag(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let bool = value as? Bool { return bool }
        if let number: Int = extractNumber(from: value) { return number != 0 }
        if let string = value as? String {
            return ["true", "1", "y", "yes", "open"].contains(string.lowercased())
        }
        return nil
    }

    private func parseSurroundViewDoors(_ doors: [String: Any]?) -> VehicleStatus.DoorStatus? {
        guard let doors else { return nil }

        func isOpen(_ key: String) -> Bool {
            parseSurroundViewFlag(doors[key]) ?? false
        }

        return VehicleStatus.DoorStatus(
            frontLeft: isOpen("frontLeft"),
            frontRight: isOpen("frontRight"),
            backLeft: isOpen("backLeft"),
            backRight: isOpen("backRight")
        )
    }
}
