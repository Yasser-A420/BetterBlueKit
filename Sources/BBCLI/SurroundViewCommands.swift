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

/// Parses a saved surround-view payload with the right region's parser.
///
/// Each region's envelope differs (Canada `result.svmLocations[]`, USA
/// `svmDetails[].svmDetail`, Kia `payload.svmInfos[]`), so the client
/// chosen with `-b`/`-r` picks the parser. For Kia, feed it an
/// `lbs/svm/inquire` response with each entry's `image` merged in — that
/// is the shape the client assembles before parsing.
@MainActor
func parseSurroundView(
    client: any APIClientProtocol,
    data: Data,
    vehicle: Vehicle
) throws -> [SurroundViewCapture] {
    switch client {
    case let canada as HyundaiCanadaAPIClient:
        return try canada.parseCanadaSurroundViewResponse(data, for: vehicle)
    case let usa as HyundaiUSAAPIClient:
        return try usa.parseUSASurroundViewResponse(data, for: vehicle)
    case let kia as KiaUSAAPIClient:
        return try kia.parseKiaSurroundViewResponse(data, for: vehicle)
    default:
        throw APIError(
            message: "This brand/region has no surround view parser. "
                + "Use -b hyundai -r CA, -b hyundai -r US, or -b kia -r US."
        )
    }
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
/// Answers whether the vehicle advertises 360 View hardware. The key path
/// it reads (`locationFeature.surroundView`) is confirmed twice over: on a
/// live Kia US account, and in the Kia owners portal's own code, which
/// reads the same path and never touches the `remoteFeature.surroundViewMonitor`
/// decoy. Prints the RAW tree anyway, so a tree that has moved is visible
/// rather than flattened into a bool.
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
        print("Fetch the gallery with command 13. Asking for a NEW capture is not supported")
        print("yet — Kia's trigger endpoint is still unknown; see KiaUSAAPIClient+SurroundView.swift.")
    case false:
        printError("locationFeature.surroundView = false — this vehicle does not advertise 360 View")
    case nil:
        printError("locationFeature.surroundView is absent from the tree above")
        print("The flag may live under a different key — check the dump.")
    }
}

// MARK: - Trigger Probe (Kia US)

/// Candidate paths for Kia's unknown 360-capture trigger, bracketed by
/// controls.
///
/// The list is REASONED, not brute-forced. Kia's `lbs/svm/` namespace
/// mixes full words (`inquire`, `info`) with three-letter codes whose
/// first letter is the verb — `dsi` reads as delete-svm-image, matching
/// `bil/pmt/dpm` (delete payment method) and `ownr/dadt`. Across the whole
/// 135-path gateway inventory the convention is consistent: `g`et, `s`et,
/// `d`elete, `r`equest. A capture trigger is a request for a new svm
/// image, so the code-shaped candidates lead with `r`, then the other
/// plausible verbs, then the full words the portal's own stripped
/// functions were named after (`triggrSvmRequest`, `initiateSvmRequest`)
/// and the app's resource string (`svm_360_locations_take_new_image`).
///
/// The two controls are what make the output readable: `inquire` is
/// known to exist and `zzzbogus` is known not to, so every candidate can
/// be compared against a real answer and a real miss from the same
/// session. Without them a lone HTTP code means nothing.
private let surroundViewTriggerCandidates = [
    "rsi", "csi", "nsi", "tsi", "ssi", "gsi",
    "request", "capture", "take", "new", "initiate", "trigger", "start", "req"
]

@MainActor
func probeSurroundViewTrigger(state: CLIState) async throws {
    guard let vehicle = selectVehicle(state: state) else { return }
    guard let token = state.authToken else {
        throw APIError(message: "Not logged in")
    }
    guard let kia = state.client as? KiaUSAAPIClient else {
        printError("The trigger probe is only implemented for Kia US")
        return
    }

    printSubheader("Probing 360 View trigger candidates for \(vehicle.model)")
    print("""

    Kia's capture trigger is undocumented; this asks the server about a short list of
    reasoned candidates and prints what comes back, uninterpreted.

    ⚠️  A candidate that IS the trigger will take a real capture. Kia caps the feature
        at five per day, so this stops at the first genuine hit.

    The two controls below calibrate everything after them. A candidate only counts as
    a hit if its errorCode differs from the KNOWN-BAD control — every answer carries a
    status block, including a path that doesn't exist, so an answer means nothing on
    its own.

    """)

    guard let missCode = await calibrateSurroundViewProbe(kia: kia, vehicle: vehicle, token: token) else {
        return
    }

    print("\nLooking for any candidate that answers something other than \(missCode).\n")

    for verb in surroundViewTriggerCandidates {
        let result = await kia.probeSurroundViewVerb(verb, for: vehicle, authToken: token)
        let differs = result.errorCode != missCode
        describeProbe(result, label: differs ? "★ candidate" : "candidate")

        if differs {
            printSuccess("`lbs/svm/\(verb)` answered errorCode "
                + "\(result.errorCode.map(String.init) ?? "none"), not the \(missCode) a "
                + "missing path returns.")
            print("That is a real signal. Stopping before another candidate spends a capture.")
            return
        }

        // Space the requests out: this is someone's own account against
        // their own vehicle, not something to hammer.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    printError("Every candidate answered errorCode \(missCode) — the same as a path that "
        + "does not exist.")
    print("""

    That is a real result, not a failure: none of these verbs exists under lbs/svm/.
    Record the list in docs/surround-view-monitor.md so it is never retried, and move
    the search to a different shape — a longer path, a different module, or a body the
    gateway requires before it will route at all.
    """)
}

private func describeProbe(_ result: KiaUSAAPIClient.SurroundViewProbeResult, label: String) {
    let status = result.httpStatus.map(String.init) ?? "—"
    let code = result.errorCode.map(String.init) ?? "none"
    print("[\(label)] lbs/svm/\(result.verb)  HTTP \(status)  errorCode \(code)")
    if let statusBlock = result.statusBlock {
        print("    status: \(statusBlock)")
    }
    print("    body:   \(result.body.prefix(300))")
}

// MARK: - Trigger Confirmation (Kia US)

/// Settles whether `lbs/svm/req` actually takes a picture.
///
/// The probe (menu 15) established only that the path EXISTS — it routes
/// where thirteen other candidates 9000'd. That is not the same as it
/// being the capture trigger: a real path handed a body it cannot use
/// answers errorCode 0 with no payload, which is exactly what `req`
/// answered, so "routed" and "worked" are indistinguishable from the
/// response alone.
///
/// The only thing that can tell them apart is the vehicle. This snapshots
/// the gallery, fires the trigger, and polls until a capture id appears
/// that wasn't there before. A new id is proof; a timeout is evidence
/// against, though not proof — the car may simply be somewhere it can't
/// answer.
@MainActor
func confirmSurroundViewTrigger(state: CLIState) async throws {
    guard let vehicle = selectVehicle(state: state) else { return }
    guard let token = state.authToken else {
        throw APIError(message: "Not logged in")
    }
    guard let kia = state.client as? KiaUSAAPIClient else {
        printError("The trigger confirmation is only implemented for Kia US")
        return
    }

    printSubheader("Confirming the 360 View trigger for \(vehicle.model)")
    print("""

    This fires lbs/svm/req and watches for a genuinely new capture.

    ⚠️  If it works, your vehicle WILL wake its cameras and take a real picture, and
        that counts against Kia's five-per-day cap. Go look at the car if you can —
        the mirrors folding out is the giveaway.

    """)

    guard prompt("Take a real capture now? (y/N): ").lowercased().hasPrefix("y") else {
        print("Cancelled — nothing was sent.")
        return
    }

    let before = try await kia.fetchSurroundViewCaptures(for: vehicle, authToken: token)
    let knownIDs = Set(before.map(\.id))
    print("\nGallery holds \(before.count) capture(s) before the request.")

    print("Sending lbs/svm/req…")
    try await kia.requestSurroundViewCapture(for: vehicle, authToken: token)
    printSuccess("Request accepted (errorCode 0).")
    print("That alone proves nothing — waiting for a capture to actually land.\n")

    // A capture takes 1-2 minutes to shoot and upload; the headroom covers
    // a modem that is slow to wake.
    let deadline = Date().addingTimeInterval(6 * 60)
    var poll = 0

    while Date() < deadline {
        try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        poll += 1

        let elapsed = Int(Date().timeIntervalSince(deadline.addingTimeInterval(-6 * 60)))
        print("Poll \(poll) (\(elapsed)s elapsed)…")

        let now = try await kia.fetchSurroundViewCaptures(for: vehicle, authToken: token)
        guard let fresh = now.first(where: { !knownIDs.contains($0.id) }) else { continue }

        printSuccess("A NEW capture landed — lbs/svm/req IS the trigger.")
        print("  captured at: \(fresh.capturedAt.map(String.init(describing:)) ?? "unknown")")
        print("  frames: \(fresh.frames.count), tiles: \(fresh.tiles.count)")
        print("""

        Confirmed. Turn the feature on for the app by adding `.surroundViewCapture` to
        KiaUSAAPIClient.optionalFeaturesSupported() — that one line restores the
        "New Capture" button. Then record it in docs/surround-view-monitor.md.
        """)
        return
    }

    printError("No new capture appeared within 6 minutes.")
    print("""

    That is evidence against `req` being the trigger, but not proof. Rule out the
    boring explanations first: the vehicle needs to be OFF and in cellular coverage,
    and Kia caps captures at five a day — a sixth request may be accepted and
    silently dropped. Re-run once those are ruled out before concluding.
    """)
}

/// Runs the three controls and returns the errorCode that means "no such
/// verb", or nil when the answers can't support any conclusion.
///
/// Split out of `probeSurroundViewTrigger` so the sweep reads as a sweep;
/// this is all setup, and it is the part that makes the sweep meaningful.
@MainActor
private func calibrateSurroundViewProbe(
    kia: KiaUSAAPIClient,
    vehicle: Vehicle,
    token: AuthToken
) async -> Int? {
    // Known-good establishes what a real path looks like; known-bad
    // establishes what a miss looks like. The miss is the baseline every
    // candidate is measured against.
    let hit = await kia.probeSurroundViewVerb("inquire", for: vehicle, authToken: token)
    describeProbe(hit, label: "CONTROL known-good")

    let miss = await kia.probeSurroundViewVerb("zzzbogus", for: vehicle, authToken: token)
    describeProbe(miss, label: "CONTROL known-bad")

    // The control that decides whether this probe can work at all.
    //
    // `info` is a REAL path that requires `{svmId}`; we send `{}`. If a
    // real path with a missing body answers the same code as a path that
    // doesn't exist, then "no such verb" and "right verb, wrong body" are
    // indistinguishable — and since nobody knows what body the trigger
    // wants, the probe would report a false negative on the correct verb.
    //
    // `info` and not `dsi`: both are real paths that need a body, but
    // `dsi` deletes, and sending it an empty body to see what happens is
    // not worth the chance it means "delete everything".
    let bodiless = await kia.probeSurroundViewVerb("info", for: vehicle, authToken: token)
    describeProbe(bodiless, label: "CONTROL real-path-no-body")

    guard let missCode = miss.errorCode else {
        printError("The known-bad control returned no errorCode — the probe has no baseline.")
        print("Without a calibrated miss, no candidate answer can be interpreted. Stopping.")
        return nil
    }
    guard hit.errorCode != missCode else {
        printError("Both controls answered errorCode \(missCode) — there is no oracle here.")
        print("A real path and a bogus one are indistinguishable, so probing cannot work.")
        return nil
    }

    print("\nBaseline: a path that does not exist answers errorCode \(missCode).")

    if bodiless.errorCode == missCode {
        printError("A REAL path sent the wrong body also answers \(missCode).")
        print("""

        That means this probe cannot tell "no such verb" from "right verb, wrong body".
        Since the trigger's body shape is unknown, a correct guess would look identical
        to a wrong one, and a negative result below would prove nothing.

        Continuing anyway — a candidate that answers something OTHER than \(missCode) is
        still a genuine hit. But treat "no hits" as inconclusive, not as a refutation.

        """)
    } else {
        printSuccess("A real path with a missing body answers "
            + "\(bodiless.errorCode.map(String.init) ?? "none"), distinct from \(missCode).")
        print("The oracle separates \"no such verb\" from \"wrong body\", so a negative")
        print("result below is meaningful.")
    }

    return missCode
}
