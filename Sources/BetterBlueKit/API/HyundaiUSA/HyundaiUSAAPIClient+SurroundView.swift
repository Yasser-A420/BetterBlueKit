//
//  HyundaiUSAAPIClient+SurroundView.swift
//  BetterBlueKit
//
//  Hyundai USA "Find My Car SVM" — the 360° camera stills.
//
//  Two endpoints under the same `/ac/v2/` base as the rest of this client:
//
//    svm/findMyCarSVM  (POST) — wakes the cameras, shoots, and uploads.
//                               Returns quickly; the image lands minutes
//                               later. Answers 502 + errorSubCode HT_533
//                               when a previous request is still pending.
//    svm/getSVMDetails (GET)  — returns the captures the server is holding
//                               (newest kept, a few retained), each with
//                               its imagery base64-encoded in `svmImage`.
//
//  The response shape and geometry were confirmed two ways: the app's own
//  bundled sample response (`assets/hma/SVMDetails.json`) and the
//  community capture in hyundai_kia_connect_api#1203. The composite is a
//  4472×720 strip described by `imageSize` — the exact format the Canada
//  client already handles — so `SurroundViewDecoder` is reused verbatim.
//
//  This differs from Hyundai Canada in the envelope, not the imagery:
//  the array is `svmDetails[].svmDetail` (Canada: `result.svmLocations[]`),
//  coordinates are nested under `gpsDetail.coord` (Canada: flat
//  `coordLat`/`coordLon`), and the trigger posts the vehicle identity in
//  the body rather than relying on a stored PIN token.
//

import Foundation

extension HyundaiUSAAPIClient {

    // MARK: - APIClientProtocol

    public func requestSurroundViewCapture(for vehicle: Vehicle, authToken: AuthToken) async throws {
        do {
            _ = try await performJSONRequest(
                url: "\(baseURL)/ac/v2/svm/findMyCarSVM",
                method: .POST,
                headers: authorizedHeaders(authToken: authToken, vehicle: vehicle),
                body: [
                    "vin": vehicle.vin,
                    "username": username,
                    "gen": String(vehicle.generation),
                    "blueLinkServicePin": pin
                ],
                requestType: .requestSurroundView,
                vin: vehicle.vin
            )
        } catch let error as APIError where error.errorType == .serverError {
            // "A capture is already pending" arrives as HTTP 502 with
            // errorSubCode HT_533; `validateHTTPResponse` folds the body
            // into the error message. Remap it so the UI shows a
            // "request in progress" state rather than a generic failure —
            // the same distinction the lock/climate commands draw.
            if error.message.contains("HT_533") {
                throw APIError.concurrentRequest(
                    "A surround view capture is already in progress. Please wait and try again.",
                    apiName: apiName
                )
            }
            throw error
        }
    }

    public func fetchSurroundViewCaptures(
        for vehicle: Vehicle,
        authToken: AuthToken
    ) async throws -> [SurroundViewCapture] {
        let (data, _, _) = try await performJSONRequest(
            url: "\(baseURL)/ac/v2/svm/getSVMDetails",
            method: .GET,
            headers: authorizedHeaders(authToken: authToken, vehicle: vehicle),
            requestType: .fetchSurroundView,
            vin: vehicle.vin
        )

        return try parseUSASurroundViewResponse(data, for: vehicle)
    }

    // MARK: - Parsing

    package func parseUSASurroundViewResponse(
        _ data: Data,
        for vehicle: Vehicle
    ) throws -> [SurroundViewCapture] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = json["svmDetails"] as? [[String: Any]] else {
            throw APIError.logError("Invalid Hyundai USA surround view response", apiName: apiName)
        }

        let captures = details.compactMap { entry -> SurroundViewCapture? in
            guard let detail = entry["svmDetail"] as? [String: Any] else { return nil }
            return parseUSASurroundViewDetail(detail, for: vehicle)
        }

        // Newest first. Observed in that order already, but nothing
        // documents the guarantee.
        return captures.sorted {
            ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast)
        }
    }

    private func parseUSASurroundViewDetail(
        _ detail: [String: Any],
        for vehicle: Vehicle
    ) -> SurroundViewCapture? {
        guard let encodedImage = detail["svmImage"] as? String,
              let imageData = Data(base64Encoded: encodedImage, options: .ignoreUnknownCharacters) else {
            BBLogger.debug(.api, "HyundaiUSA: skipping surround view entry without decodable image")
            return nil
        }

        let frames = SurroundViewDecoder.extractJPEGFrames(from: imageData)
        guard !frames.isEmpty else {
            BBLogger.debug(.api, "HyundaiUSA: surround view entry contained no JPEG frames")
            return nil
        }

        let imageSize = (detail["imageSize"] as? [Any])?.compactMap { extractNumber(from: $0) as Int? } ?? []
        let gpsDetail = detail["gpsDetail"] as? [String: Any]
        let heading: Int? = extractNumber(from: gpsDetail?["head"])

        return SurroundViewCapture(
            vin: vehicle.vin,
            capturedAt: parseUSASurroundViewTimestamp(gpsDetail?["time"]),
            location: parseUSASurroundViewLocation(gpsDetail),
            heading: heading,
            doorOpen: parseUSASurroundViewDoors(detail["doorOpen"] as? [String: Any]),
            trunkOpen: parseUSASurroundViewFlag(detail["trunkOpen"]),
            sideMirrorOpen: parseUSASurroundViewFlag(detail["sidemirrorOpen"]),
            frames: frames,
            tiles: SurroundViewDecoder.tiles(imageSize: imageSize, frameCount: frames.count)
        )
    }

    /// `gpsDetail.time` is a bare `yyyyMMddHHmmss` stamp, e.g.
    /// "20190913231516".
    ///
    /// Read as UTC to match the Canada client and because the app renders
    /// the capture time in the user's own timezone regardless. This is the
    /// one field not yet verified against a live USA capture — if a real
    /// capture shows the vehicle's local time here, this needs the account
    /// offset applied instead.
    private func parseUSASurroundViewTimestamp(_ value: Any?) -> Date? {
        guard let raw = value as? String, raw.count == 14 else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    /// USA nests coordinates as `gpsDetail.coord.{lat,lon}`, unlike the flat
    /// `coordLat`/`coordLon` pair the Canada SVM endpoints return.
    private func parseUSASurroundViewLocation(_ gpsDetail: [String: Any]?) -> VehicleStatus.Location? {
        guard let coord = gpsDetail?["coord"] as? [String: Any],
              let latitude: Double = extractNumber(from: coord["lat"]),
              let longitude: Double = extractNumber(from: coord["lon"]) else {
            return nil
        }

        let location = VehicleStatus.Location(latitude: latitude, longitude: longitude)
        return location.hasCoordinates ? location : nil
    }

    private func parseUSASurroundViewDoors(_ doors: [String: Any]?) -> VehicleStatus.DoorStatus? {
        guard let doors else { return nil }

        func isOpen(_ key: String) -> Bool {
            parseUSASurroundViewFlag(doors[key]) ?? false
        }

        return VehicleStatus.DoorStatus(
            frontLeft: isOpen("frontLeft"),
            frontRight: isOpen("frontRight"),
            backLeft: isOpen("backLeft"),
            backRight: isOpen("backRight")
        )
    }

    /// Reads an open/closed flag that may arrive as a JSON boolean or as
    /// 0/1 (the sample response uses `0`/`1`). Nil only when the key is
    /// absent, so "closed" and "not reported" stay distinguishable.
    private func parseUSASurroundViewFlag(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let bool = value as? Bool { return bool }
        if let number: Int = extractNumber(from: value) { return number != 0 }
        if let string = value as? String {
            return ["true", "1", "y", "yes", "open"].contains(string.lowercased())
        }
        return nil
    }
}
