//
//  KiaUSAAPIClient+SurroundView.swift
//  BetterBlueKit
//
//  Kia US "360 View" — capability detection only, on purpose.
//
//  Kia brands this feature "360 View", not "Surround View Monitor", which
//  is why searching the open-source ecosystem for "surround"/"SVM" finds
//  nothing on the Kia side. It is real and well attested: the owner's
//  manual and Kia Connect terms describe remotely opening the mirrors to
//  photograph all four sides plus a bird's-eye view, capped at five
//  captures a day with ten retained in the owner's portal.
//
//  What is NOT known is the wire protocol. Nothing public documents it:
//
//    * Sam Curry's June 2024 Kia disclosure enumerated the whole
//      `apigwServlet` / `api.owners.kia.com` grammar — `/prof/authUser`,
//      `/ownr/dicve`, `/door/unlock`, `/dec/dlr/rvp` and more — and names
//      "Remote Camera" only as a row in a feature table. No path, no
//      request body, no response shape.
//    * `hyundai_kia_connect_api`, `bluelinky`, `kia_uvo` and
//      `ha_kia_hyundai_USA` have no Kia-side camera code at all.
//    * The Hyundai USA spelling (`ac/v2/svm/findMyCarSVM`,
//      `svm/getSVMDetails`) has no Kia analogue — different host,
//      different path grammar, different auth and error conventions — so
//      it cannot be transplanted.
//
//  So this file stops deliberately short of the wire. It answers the one
//  question that CAN be answered from the API we already speak — does
//  this vehicle report 360-view hardware — and leaves the endpoints to a
//  proxy capture of the Kia Access app or the owners.kia.com portal.
//  Guessing a URL here would be worse than useless: `checkForKiaErrors`
//  silently ignores error codes it doesn't recognise, so a wrong path
//  fails as an opaque parse error several frames away.
//
//  NOTE: `optionalFeaturesSupported()` deliberately does NOT list
//  `.surroundView`. That one line is the app-wide switch that puts the
//  "Surround View" item in the vehicle menu; it stays off until there is
//  an endpoint behind it.
//

import Foundation

extension KiaUSAAPIClient {

    /// Asks `cmm/gvi` for the vehicle's feature tree.
    ///
    /// The production status call sends `vehicleFeature: "0"`, which
    /// suppresses this block entirely — the app has never seen it. Sending
    /// `"1"` is what a sibling project (`ha_kia_hyundai_USA`) does to read
    /// `vehicleConfig.vehicleFeature.remoteFeature.*`, so the tree is
    /// known to be reachable; whether it carries `locationFeature` is the
    /// hypothesis this probe tests.
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

        // Surface the server's own status block when the tree is absent:
        // an unrecognised error code would otherwise reach the caller as
        // an empty dictionary, which reads as "no features" rather than
        // "the request was refused".
        guard let payload = json["payload"] as? [String: Any],
              let config = payload["vehicleConfig"] as? [String: Any],
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
    /// Reads `vehicleFeature.locationFeature.surroundView`. That key path
    /// comes from `huttotw/homebridge-kia-connect`, which types it against
    /// a real Kia USA response — note Kia files it under `locationFeature`
    /// beside `lastMile`, the same way Hyundai names its endpoint
    /// `findMyCarSVM`: both treat remote cameras as a find-my-car feature
    /// rather than a remote command.
    ///
    /// Returns nil when the key is absent, which is NOT the same as false
    /// — it means this build's guess about where the flag lives is wrong,
    /// and the raw tree should be read instead.
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
