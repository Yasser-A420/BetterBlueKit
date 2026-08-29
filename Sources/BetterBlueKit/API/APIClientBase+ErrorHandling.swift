//
//  APIClientBase+ErrorHandling.swift
//  BetterBlueKit
//
//  HTTP + CCSP response validation, split out of APIClientBase to keep the
//  class body within the library's default lint thresholds.
//

import Foundation

extension APIClientBase {

    // MARK: - Error Handling

    func validateHTTPResponse(_ httpResponse: HTTPURLResponse, data: Data, responseBody: String?) throws {
        // CCSP (the EU/AU/IN "Connected Car Service Platform") reports
        // application-level failures inside the body — `retCode: "F"` plus a
        // numeric `resCode` — and usually pairs them with an unhelpful HTTP
        // 400. Decode those first so a duplicate/timeout/rate-limit surfaces
        // as a typed, user-facing error instead of "HTTP 400: bad request".
        try checkCCSPResponseForErrors(data: data)

        if httpResponse.statusCode == 401 {
            throw APIError.invalidCredentials(
                "Authentication expired: \(responseBody ?? "Unknown error")",
                apiName: apiName
            )
        }

        if httpResponse.statusCode == 502 {
            throw APIError.serverError(
                "Server error (502): \(responseBody ?? "Unknown error")",
                apiName: apiName
            )
        }

        if httpResponse.statusCode >= 400 {
            let statusText = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw APIError(
                message: "HTTP \(httpResponse.statusCode): \(statusText)",
                code: httpResponse.statusCode,
                apiName: apiName
            )
        }
    }

    /// Translate a CCSP `retCode: "F"` error envelope into a typed `APIError`.
    ///
    /// A no-op for any response that isn't a CCSP envelope (no `retCode`/
    /// `resCode`), so the US/Canada/China clients are unaffected. The codes
    /// and their meanings track Home Assistant's `hyundai_kia_connect_api`
    /// `_check_response_for_errors`, which is the reference implementation for
    /// the European Hyundai/Kia API.
    func checkCCSPResponseForErrors(data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["retCode"] as? String == "F",
              let resCode = json["resCode"] as? String else {
            return
        }
        let resMsg = (json["resMsg"] as? String) ?? "Unknown error"

        switch resCode {
        case "7501": // "Key not authorized" / token expired
            throw APIError.invalidCredentials(
                "Authentication expired — please sign in again.", apiName: apiName
            )
        case "4002": // Invalid deviceId — re-registering the device fixes it
            throw APIError.invalidVehicleSession(
                "Invalid device ID — please sign out and back in.", apiName: apiName
            )
        case "4004": // A previous command is still queued server-side
            throw APIError.concurrentRequest(
                "A previous command is still being processed. Please wait a moment and try again.",
                apiName: apiName
            )
        case "4005": // Control action not supported for this vehicle
            throw APIError(
                message: "This action isn't supported for this vehicle.",
                code: 400, apiName: apiName
            )
        case "4081", "9999": // Request/response timeout
            throw APIError.serverError(
                "The request timed out. Please try again.", apiName: apiName
            )
        case "5031": // Remote control temporarily unavailable
            throw APIError.serverError(
                "Remote control is temporarily unavailable. Please try again later.",
                apiName: apiName
            )
        case "5091": // Exceeds number of requests
            throw APIError.serverError(
                "Too many requests — please wait a while before trying again.",
                apiName: apiName
            )
        case "5921": // No data found yet
            throw APIError(
                message: "No data available from the vehicle yet. Try refreshing in a moment.",
                code: 400, apiName: apiName
            )
        default:
            throw APIError(
                message: "Server returned \(resCode): \(resMsg)",
                code: 400, apiName: apiName
            )
        }
    }

    func handleNetworkError(_ error: Error, context: RequestContext) -> APIError {
        logHTTPRequest(createErrorLogData(context: context, error: error.localizedDescription))
        return APIError(message: "Network error: \(error.localizedDescription)", apiName: apiName)
    }
}
