//
//  HyundaiCanada+Location.swift
//  BetterBlueKit
//
//  Hyundai Canada vehicle location.
//
//  Split out of the client for size, but the code is one idea: this
//  region has changed which endpoint/header pairing answers with
//  coordinates at least twice, and the answer differs between accounts,
//  so location is a ladder of strategies with the winner remembered.
//

import Foundation

extension HyundaiCanadaAPIClient {

    /// One way of asking this API where the vehicle is.
    ///
    /// The accepted combination has moved twice now — BetterBlueKit#36
    /// switched the web-portal variant to `evc/fme` with native-app
    /// headers, and a later account found `evc/fme` timing out on every
    /// request while `fndmcr` answered, but only to the native-app
    /// identity (`from: CWP` drew errorCode 6459 in the same second
    /// `from: SPA` returned coordinates). Both reports are first-hand
    /// and neither generalizes, so try each in turn instead of betting
    /// the region on one.
    enum LocationStrategy: String, CaseIterable {
        /// `fndmcr` with the native-app identity, whichever variant the
        /// account logs in with. Most recently verified.
        case findMyCarNative
        /// `fndmcr` with this account's own login identity.
        case findMyCarAccount
        /// `evc/fme` with the native-app identity — the pairing a
        /// Canadian owner verified in BetterBlueKit#36. Kept last rather
        /// than deleted: it was right for at least one real account, and
        /// nothing shows it is dead everywhere.
        case findMyElectricNative

        var path: String {
            switch self {
            case .findMyCarNative, .findMyCarAccount: "fndmcr"
            case .findMyElectricNative: "evc/fme"
            }
        }
    }

    /// Fetches the vehicle's location, remembering which strategy worked.
    ///
    /// `injectLocationCoordinates` runs on *every* status fetch, so
    /// without memoizing the winner an account served by the second or
    /// third strategy would re-pay every failed request on every refresh
    /// — against an API whose WAF has rate-limited this project before.
    func fetchLocationData(vehicle: Vehicle, authToken: AuthToken, pAuth: String) async throws -> Data {
        var firstError: Error?

        for strategy in orderedLocationStrategies() {
            do {
                let data = try await sendLocationRequest(
                    strategy: strategy,
                    vehicle: vehicle,
                    authToken: authToken,
                    pAuth: pAuth
                )
                if locationStrategy != strategy {
                    BBLogger.info(.api, "HyundaiCanada: location strategy \(strategy.rawValue) works; remembering it")
                    locationStrategy = strategy
                }
                return data
            } catch {
                firstError = firstError ?? error
                BBLogger.debug(.api, "HyundaiCanada: location strategy \(strategy.rawValue) failed: \(error)")
            }
        }

        // Nothing worked. Forget any stale winner and stamp the sweep so
        // the next status refresh retries one strategy rather than all.
        locationStrategy = nil
        lastLocationSweep = Date()

        // Surface the FIRST failure: later strategies are progressively
        // less likely to fit this account, so their errors are usually
        // less informative than the preferred combination's.
        throw firstError ?? APIError.logError("No Canada location strategy succeeded", apiName: apiName)
    }

    /// Strategies to try, most-likely first.
    private func orderedLocationStrategies() -> [LocationStrategy] {
        if let remembered = locationStrategy {
            return [remembered] + LocationStrategy.allCases.filter { $0 != remembered }
        }
        if let lastLocationSweep, Date().timeIntervalSince(lastLocationSweep) < Self.locationSweepInterval {
            // A recent sweep found nothing. Retry just the leading
            // strategy until the backoff expires; a vehicle that simply
            // has location disabled shouldn't cost three calls a refresh.
            return Array(LocationStrategy.allCases.prefix(1))
        }
        return LocationStrategy.allCases
    }

    private func sendLocationRequest(
        strategy: LocationStrategy,
        vehicle: Vehicle,
        authToken: AuthToken,
        pAuth: String
    ) async throws -> Data {
        let headers = switch strategy {
        case .findMyCarNative, .findMyElectricNative:
            locationHeaders(authToken: authToken, vehicleId: vehicle.regId, pAuth: pAuth)
        case .findMyCarAccount:
            authorizedHeaders(authToken: authToken, vehicleId: vehicle.regId, pAuth: pAuth)
        }

        let (data, _, _) = try await performJSONRequest(
            url: "\(apiBaseURL)/\(strategy.path)",
            method: .POST,
            headers: headers,
            body: ["pin": pin],
            requestType: .fetchVehicleStatus,
            vin: vehicle.vin
        )

        // Validated here so an API-level refusal (HTTP 200 with
        // `responseCode: 1`) still moves on to the next strategy.
        _ = try parseCanadaResponse(data, context: "location")
        return data
    }
}
