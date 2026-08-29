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

        // Canada stamps the capture at the top level as `utcTime`; the
        // `gpsDetail.time` fallback is the parser's default. Coordinates
        // arrive flat as `coordLat`/`coordLon` rather than in the
        // `coord: { lat, lon }` object the status endpoints use, which
        // the default shape already covers.
        return SurroundViewCaptureParser.captures(
            from: locations,
            vin: vehicle.vin,
            shape: .init(timestamp: [["utcTime"], ["gpsDetail", "time"]]),
            apiName: apiName
        )
    }
}
