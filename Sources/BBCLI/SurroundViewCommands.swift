//
//  SurroundViewCommands.swift
//  BBCLI
//
//  Surround View Monitor commands: ask the vehicle for a fresh capture,
//  fetch what the server is holding, and dump the frames to disk.
//
//  Split out of `main.swift` to keep that file under its length limit —
//  these four functions are self-contained and share no state with the
//  interactive loop beyond `CLIState`.
//

import BetterBlueKit
import Foundation

// MARK: - Surround View

@MainActor
func requestSurroundView(state: CLIState) async throws {
    guard let vehicle = selectVehicle(state: state) else { return }
    guard let token = state.authToken else {
        throw APIError(message: "Not logged in")
    }
    guard let client = state.client else {
        throw APIError(message: "No API client initialized")
    }

    printSubheader("Requesting Surround View Capture for \(vehicle.model)")

    try await client.requestSurroundViewCapture(for: vehicle, authToken: token)

    printSuccess("Capture requested")
    print("The vehicle now wakes its cameras, shoots, and uploads.")
    print("Wait 1-2 minutes, then run command 13 to fetch the images.")
}

@MainActor
func fetchSurroundView(state: CLIState) async throws {
    guard let vehicle = selectVehicle(state: state) else { return }
    guard let token = state.authToken else {
        throw APIError(message: "Not logged in")
    }
    guard let client = state.client else {
        throw APIError(message: "No API client initialized")
    }

    printSubheader("Fetching Surround View for \(vehicle.model)")

    let captures = try await client.fetchSurroundViewCaptures(for: vehicle, authToken: token)
    printSuccess("Found \(captures.count) capture(s)")

    let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("surround-view")

    for (index, capture) in captures.enumerated() {
        print("\n[\(index + 1)] Captured: \(capture.capturedAt.map(String.init(describing:)) ?? "unknown")")
        print("    Frames: \(capture.frames.count) (\(capture.byteCount / 1024) KB)")
        if let heading = capture.heading {
            print("    Heading: \(heading)°")
        }
        if capture.location != nil {
            print("    Location: [redacted — see HTTP log with --no-redaction]")
        }
        for tile in capture.tiles {
            if let crop = tile.crop {
                print("    Tile \(tile.position.displayName): "
                    + "\(crop.width)x\(crop.height) at x=\(crop.originX) in frame \(tile.frameIndex)")
            } else {
                print("    Tile \(tile.position.displayName): whole frame \(tile.frameIndex)")
            }
        }

        for (frameIndex, frame) in capture.frames.enumerated() {
            let stamp = capture.capturedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            let file = outputDirectory.appendingPathComponent("\(stamp)-frame\(frameIndex).jpg")
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try frame.write(to: file)
            print("    Wrote \(file.path)")
        }
    }
}

@MainActor
func parseSurroundView(
    client: any APIClientProtocol,
    data: Data,
    vehicle: Vehicle
) throws -> [SurroundViewCapture] {
    guard let hyundaiCanada = client as? HyundaiCanadaAPIClient else {
        throw APIError(message: "Unsupported client type for surround view parsing")
    }
    return try hyundaiCanada.parseCanadaSurroundViewResponse(data, for: vehicle)
}

/// Prints what each capture holds and writes its frames to disk, so a
/// saved payload can be checked without a vehicle in the loop.
/// Coordinates are deliberately not printed — the images and their GPS
/// fix say exactly where the car (and usually its owner) was.
func describeSurroundViewCaptures(_ captures: [SurroundViewCapture]) throws {
    let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("surround-view")

    for (index, capture) in captures.enumerated() {
        print("\n[\(index + 1)] Captured: \(capture.capturedAt.map(String.init(describing:)) ?? "unknown")")
        print("    Frames: \(capture.frames.count) (\(capture.byteCount / 1024) KB)")
        print("    Has location: \(capture.location != nil)")
        if let heading = capture.heading {
            print("    Heading: \(heading)°")
        }
        if let doors = capture.doorOpen {
            print("    Doors open: \(doors.anyOpen ? doors.openDoorsDescription : "none")")
        }
        for tile in capture.tiles {
            if let crop = tile.crop {
                print("    Tile \(tile.position.displayName): "
                    + "\(crop.width)x\(crop.height) at x=\(crop.originX) in frame \(tile.frameIndex)")
            } else {
                print("    Tile \(tile.position.displayName): whole frame \(tile.frameIndex)")
            }
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for (frameIndex, frame) in capture.frames.enumerated() {
            let stamp = capture.capturedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            let file = outputDirectory.appendingPathComponent("\(stamp)-frame\(frameIndex).jpg")
            try frame.write(to: file)
            print("    Wrote \(file.path)")
        }
    }
}

// MARK: - Feature Probe (Kia US)

/// Dumps the vehicle's feature tree from `cmm/gvi`.
///
/// The one honest step available toward Kia US 360 View: it answers
/// whether the vehicle advertises the hardware, without guessing at the
/// endpoints that would actually fetch images. Prints the RAW tree rather
/// than just a verdict, because the key path this reads
/// (`locationFeature.surroundView`) is a hypothesis taken from one
/// third-party project's type definitions — if the flag lives somewhere
/// else, the dump is what shows you where.
@MainActor
func probeVehicleFeatures(state: CLIState) async throws {
    guard let vehicle = selectVehicle(state: state) else { return }
    guard let token = state.authToken else {
        throw APIError(message: "Not logged in")
    }
    guard let kia = state.client as? KiaUSAAPIClient else {
        printError("Feature probing is only implemented for Kia US")
        return
    }

    printSubheader("Probing Feature Tree for \(vehicle.model)")

    let features = try await kia.fetchVehicleFeatureTree(for: vehicle, authToken: token)

    if let pretty = try? JSONSerialization.data(withJSONObject: features, options: [.prettyPrinted, .sortedKeys]),
       let text = String(bytes: pretty, encoding: .utf8) {
        print(text)
    } else {
        print(features)
    }

    print("")
    switch try await kia.reportsSurroundView(for: vehicle, authToken: token) {
    case true:
        printSuccess("locationFeature.surroundView = true — this vehicle advertises 360 View")
        print("The endpoints are still unknown; see KiaUSAAPIClient+SurroundView.swift.")
    case false:
        printError("locationFeature.surroundView = false — this vehicle does not advertise 360 View")
    case nil:
        printError("locationFeature.surroundView is absent from the tree above")
        print("The flag may live under a different key — check the dump.")
    }
}
