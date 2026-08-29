//
//  KiaUSASurroundViewTests.swift
//  BetterBlueKit
//
//  Parsing coverage for Kia US "360 View". The payload shape comes from
//  the Kia owners portal's own compiled client, which lists captures with
//  `POST /lbs/svm/inquire` (`payload.svmInfos[]`, each carrying `svmId`,
//  `imageViewed` and `location.{syncDate,coord}`) and then fetches each
//  image with `POST /lbs/svm/info` (`payload.svmInfos[0].image`).
//
//  The client merges the image back into its metadata entry before
//  parsing, so these fixtures are shaped the same way: an `inquire` entry
//  with an `image` key added.
//

import Foundation
import Testing
@testable import BetterBlueKit

// `.serialized` because the URLProtocol stub below keeps process-wide
// static state; parallel tests would interleave each other's responses.
@Suite("Kia US Surround View", .serialized)
struct KiaUSASurroundViewTests {

    /// Bytes that merely look like a JPEG — the decoder splits on markers
    /// and never parses the image itself.
    private func fakeJPEG(marker: UInt8, padding: Int = 8) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        data.append(contentsOf: Array(repeating: marker, count: padding))
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }

    /// A JPEG carrying a real SOF0 header, so the decoder can read its
    /// dimensions. Not a decodable image — only the header is parsed.
    private func sizedJPEG(width: Int, height: Int, marker: UInt8 = 0x11) -> Data {
        var data = Data([0xFF, 0xD8])
        data.append(contentsOf: [0xFF, 0xE0, 0x00, 0x04, marker, marker])
        data.append(contentsOf: [
            0xFF, 0xC0, 0x00, 0x11, 0x08,
            UInt8(height >> 8), UInt8(height & 0xFF),
            UInt8(width >> 8), UInt8(width & 0xFF)
        ])
        data.append(contentsOf: Array(repeating: marker, count: 8))
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }

    @MainActor
    private func makeClient() -> KiaUSAAPIClient {
        KiaUSAAPIClient(configuration: APIClientConfiguration(
            region: .usa,
            brand: .kia,
            username: "test@example.com",
            password: "password123",
            pin: "1234",
            accountId: UUID()
        ))
    }

    private func makeVehicle() -> Vehicle {
        Vehicle(
            vin: "TESTVIN0000000000",
            regId: "reg",
            model: "CARNIVAL",
            accountId: UUID(),
            fuelType: .gas,
            generation: 3,
            odometer: Distance(length: 0, units: .kilometers)
        )
    }

    /// One merged entry, shaped like the portal's own reading of the
    /// response: `svmId`, `imageViewed`, `location.syncDate.utc` and
    /// `location.coord`, plus the image the second call supplies.
    private func makePayload(entries: [(id: Int, utc: String, marker: UInt8)]) -> Data {
        let infos = entries.map { entry in
            """
            {
              "svmId": \(entry.id),
              "imageViewed": "1",
              "location": {
                "syncDate": {"utc": "\(entry.utc)", "offset": -5},
                "coord": {"lat": 42.271284, "lon": -83.625744, "alt": 0, "altdo": 0, "type": 0},
                "head": 67,
                "speed": {"value": 0, "unit": 0}
              },
              "status": 0,
              "image": "\(fakeJPEG(marker: entry.marker).base64EncodedString())"
            }
            """
        }.joined(separator: ",")

        return Data("""
        {"status": {"statusCode": 0, "errorCode": 0, "errorMessage": ""},
         "payload": {"svmInfos": [\(infos)]}}
        """.utf8)
    }

    @Test("A capture's imagery and metadata parse")
    @MainActor func testParsesCapture() throws {
        let captures = try makeClient().parseKiaSurroundViewResponse(
            makePayload(entries: [(id: 501, utc: "20260826003935", marker: 0x11)]),
            for: makeVehicle()
        )

        let capture = try #require(captures.first)
        #expect(capture.vin == "TESTVIN0000000000")
        #expect(capture.frames.count == 1)
        #expect(capture.location?.latitude == 42.271284)
        #expect(capture.location?.longitude == -83.625744)
    }

    /// `location.syncDate.utc` is the same bare `yyyyMMddHHmmss` string
    /// every region uses, just nested one level deeper. Its sibling
    /// `offset` is the vehicle's local timezone and is deliberately
    /// ignored — the app renders capture times in the user's own zone.
    @Test("location.syncDate.utc is read as UTC")
    @MainActor func testTimestampIsUTC() throws {
        let capture = try #require(try makeClient().parseKiaSurroundViewResponse(
            makePayload(entries: [(id: 501, utc: "20260826003935", marker: 0x11)]),
            for: makeVehicle()
        ).first)

        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 26
        components.hour = 0; components.minute = 39; components.second = 35
        components.timeZone = TimeZone(identifier: "UTC")

        let expected = try #require(Calendar(identifier: .gregorian).date(from: components))
        #expect(capture.capturedAt == expected)
    }

    /// Kia sends no `imageSize`, so the geometry has to come from the
    /// strip itself. When the frame's dimensions can't be read either,
    /// the decoder must fall back to one whole-frame composite tile
    /// rather than inventing Hyundai's panel widths.
    @Test("A capture with no imageSize and no readable dimensions stays whole")
    @MainActor func testNoImageSizeFallsBackToComposite() throws {
        let capture = try #require(try makeClient().parseKiaSurroundViewResponse(
            makePayload(entries: [(id: 501, utc: "20260826003935", marker: 0x11)]),
            for: makeVehicle()
        ).first)

        #expect(capture.tiles.count == 1)
        #expect(capture.tiles.first?.position == .composite)
        #expect(capture.tiles.first?.crop == nil)
    }

    /// The real thing: a Kia capture is a 4472x720 composite carrying no
    /// `imageSize` at all. Confirmed against a live Carnival — the strip
    /// measures exactly what Hyundai states outright, so the five camera
    /// views must be recovered from the frame's own dimensions. Without
    /// this the whole capture renders as one unreadable 6:1 strip and the
    /// camera picker disappears.
    @Test("A real 4472x720 Kia capture tiles into five camera views")
    @MainActor func testRealCaptureTilesFromFrameDimensions() throws {
        let image = sizedJPEG(width: 4472, height: 720).base64EncodedString()
        let payload = Data("""
        {"payload": {"svmInfos": [{
          "svmId": 501,
          "location": {"syncDate": {"utc": "20260826003935"}, "coord": {"lat": 42.27, "lon": -83.62}},
          "image": "\(image)"
        }]}}
        """.utf8)

        let capture = try #require(
            try makeClient().parseKiaSurroundViewResponse(payload, for: makeVehicle()).first
        )

        #expect(capture.tiles.count == 5)
        #expect(capture.tiles.map(\.position) == [.front, .rear, .left, .right, .topDown])
        #expect(capture.tiles[0].crop?.width == 960)
        #expect(capture.tiles[4].crop?.width == 632)
    }

    /// Heading sits at `location.head`, beside the fix rather than inside
    /// it — confirmed against a live capture.
    @Test("Heading is read from location.head")
    @MainActor func testHeadingIsRead() throws {
        let capture = try #require(try makeClient().parseKiaSurroundViewResponse(
            makePayload(entries: [(id: 501, utc: "20260826003935", marker: 0x11)]),
            for: makeVehicle()
        ).first)

        #expect(capture.heading == 67)
    }

    /// A real Kia entry carries no door, trunk or mirror state — the
    /// shape leaves them unmapped rather than guessing key names, and
    /// they must read as "not reported" rather than as "closed".
    @Test("Door and trunk state Kia never sends stays nil")
    @MainActor func testUnmappedFieldsAreNil() throws {
        let capture = try #require(try makeClient().parseKiaSurroundViewResponse(
            makePayload(entries: [(id: 501, utc: "20260826003935", marker: 0x11)]),
            for: makeVehicle()
        ).first)

        #expect(capture.doorOpen == nil)
        #expect(capture.trunkOpen == nil)
        #expect(capture.sideMirrorOpen == nil)
    }

    /// Hyundai's key names must NOT leak into the Kia shape — an entry
    /// that only carries `svmImage` has no image as far as Kia is
    /// concerned, and must be skipped rather than half-parsed.
    @Test("A Hyundai-shaped entry is not mistaken for a Kia one")
    @MainActor func testHyundaiKeysAreNotRead() throws {
        let payload = Data("""
        {"payload": {"svmInfos": [{
          "svmId": 1,
          "gpsDetail": {"coord": {"lat": 42.0, "lon": -83.0}, "time": "20260826003935", "head": 93},
          "svmImage": "\(fakeJPEG(marker: 0x11).base64EncodedString())"
        }]}}
        """.utf8)

        let captures = try makeClient().parseKiaSurroundViewResponse(payload, for: makeVehicle())
        #expect(captures.isEmpty)
    }

    @Test("Captures are returned newest first")
    @MainActor func testSortedNewestFirst() throws {
        let captures = try makeClient().parseKiaSurroundViewResponse(
            makePayload(entries: [
                (id: 1, utc: "20260713192923", marker: 0x11),
                (id: 2, utc: "20260826003935", marker: 0x22),
                (id: 3, utc: "20260806221826", marker: 0x33)
            ]),
            for: makeVehicle()
        )

        #expect(captures.count == 3)
        let timestamps = captures.compactMap(\.capturedAt)
        #expect(timestamps == timestamps.sorted(by: >))
    }

    /// An account that has never taken a capture gets a well-formed
    /// payload with nothing in it — that is not an error.
    @Test("An empty gallery parses as no captures")
    @MainActor func testEmptyGallery() throws {
        let payload = Data("""
        {"status": {"statusCode": 0, "errorCode": 0}, "payload": {"svmInfos": []}}
        """.utf8)

        #expect(try makeClient().parseKiaSurroundViewResponse(payload, for: makeVehicle()).isEmpty)
    }

    @Test("A response without a payload throws")
    @MainActor func testMissingPayloadThrows() throws {
        let payload = Data(#"{"status": {"statusCode": 0, "errorCode": 0}}"#.utf8)

        #expect(throws: APIError.self) {
            try makeClient().parseKiaSurroundViewResponse(payload, for: makeVehicle())
        }
    }

    /// The Kia envelope reports refusals as an `errorCode` inside an
    /// HTTP 200 body, so the parser has to check it before walking the
    /// payload — otherwise a session error surfaces as a parse failure.
    @Test("A Kia error envelope surfaces as its own error")
    @MainActor func testErrorEnvelopeThrows() throws {
        let payload = Data("""
        {"status": {"statusCode": 1, "errorCode": 1005, "errorMessage": "Session expired"}}
        """.utf8)

        let error = #expect(throws: APIError.self) {
            try makeClient().parseKiaSurroundViewResponse(payload, for: makeVehicle())
        }
        #expect(error?.errorType == .invalidVehicleSession)
    }

    // MARK: - The three-call fetch

    /// Stubs `URLSession` so the inquire → info → merge flow can be driven
    /// end to end.
    ///
    /// Responses are keyed by the path suffix of the request and held as a
    /// QUEUE, popped in order — the image pass calls the same `info` path
    /// once per capture, so a single response per path could not express
    /// "the second image fails". The last entry repeats once the queue is
    /// down to it, which keeps the common "same answer every time" case a
    /// one-element array.
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responses: [String: [(Int, String)]] = [:]
        nonisolated(unsafe) static var requestedPaths: [String] = []

        static func reset(_ responses: [String: [(Int, String)]]) {
            Self.responses = responses
            Self.requestedPaths = []
        }

        static func callCount(forPathSuffix suffix: String) -> Int {
            requestedPaths.filter { $0.hasSuffix(suffix) }.count
        }

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            Self.requestedPaths.append(path)

            var answer = (404, "{}")
            if let key = Self.responses.keys.first(where: { path.hasSuffix($0) }),
               let queued = Self.responses[key]?.first {
                answer = queued
                if let count = Self.responses[key]?.count, count > 1 {
                    Self.responses[key]?.removeFirst()
                }
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: answer.0,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!

            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @MainActor
    private func makeStubbedClient() -> KiaUSAAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]

        return KiaUSAAPIClient(
            configuration: APIClientConfiguration(
                region: .usa,
                brand: .kia,
                username: "test@example.com",
                password: "password123",
                pin: "1234",
                accountId: UUID()
            ),
            urlSession: URLSession(configuration: configuration)
        )
    }

    private var stubToken: AuthToken {
        AuthToken(accessToken: "sid", refreshToken: "", expiresAt: Date().addingTimeInterval(3600))
    }

    private func inquireBody(ids: [Int]) -> String {
        let infos = ids.map {
            """
            {"svmId": \($0), "location": {"syncDate": {"utc": "2026082600393\($0 % 10)"},
             "coord": {"lat": 42.27, "lon": -83.62}}}
            """
        }.joined(separator: ",")
        return #"{"status":{"statusCode":0,"errorCode":0},"payload":{"svmInfos":[\#(infos)]}}"#
    }

    private func infoBody(marker: UInt8) -> String {
        let image = fakeJPEG(marker: marker).base64EncodedString()
        return #"{"status":{"statusCode":0,"errorCode":0},"payload":{"svmInfos":[{"image":"\#(image)"}]}}"#
    }

    @Test("The inquire → info flow assembles captures")
    @MainActor func testThreeCallFlow() async throws {
        StubProtocol.reset([
            "lbs/svm/inquire": [(200, inquireBody(ids: [1, 2]))],
            "lbs/svm/info": [(200, infoBody(marker: 0x11))]
        ])

        let captures = try await makeStubbedClient()
            .fetchSurroundViewCaptures(for: makeVehicle(), authToken: stubToken)

        #expect(captures.count == 2)
        // One list call plus one image call per capture.
        #expect(StubProtocol.callCount(forPathSuffix: "lbs/svm/inquire") == 1)
        #expect(StubProtocol.callCount(forPathSuffix: "lbs/svm/info") == 2)
    }

    /// A gallery that lists captures but whose imagery can't be fetched
    /// must NOT look like an empty gallery. Returning [] there renders as
    /// "No Captures Yet" over a full gallery and hides the only clue a bug
    /// report would carry — which is exactly how a response that nests the
    /// image somewhere unexpected would present.
    @Test("A total image-fetch failure throws rather than reporting an empty gallery")
    @MainActor func testTotalImageFailureThrows() async {
        StubProtocol.reset([
            "lbs/svm/inquire": [(200, inquireBody(ids: [1, 2]))],
            "lbs/svm/info": [(200, #"{"status":{"statusCode":0,"errorCode":0},"payload":{}}"#)]
        ])

        await #expect(throws: APIError.self) {
            try await self.makeStubbedClient()
                .fetchSurroundViewCaptures(for: self.makeVehicle(), authToken: self.stubToken)
        }
    }

    /// A dead session must reach `BBAccount`, which knows how to
    /// re-authenticate and retry. Swallowing it into an empty result
    /// leaves the user staring at "No Captures Yet" with no recovery.
    @Test("A session error during the image pass propagates for re-authentication")
    @MainActor func testSessionErrorPropagates() async {
        StubProtocol.reset([
            "lbs/svm/inquire": [(200, inquireBody(ids: [1, 2, 3]))],
            "lbs/svm/info": [(200, #"""
            {"status":{"statusCode":1,"errorCode":1005,"errorMessage":"Session expired"}}
            """#)]
        ])

        let error = await #expect(throws: APIError.self) {
            try await self.makeStubbedClient()
                .fetchSurroundViewCaptures(for: self.makeVehicle(), authToken: self.stubToken)
        }

        #expect(error?.errorType == .invalidVehicleSession)
        // It must bail on the FIRST dead-session answer rather than
        // re-trying every remaining id against a session it knows is gone.
        #expect(StubProtocol.callCount(forPathSuffix: "lbs/svm/info") == 1)
    }

    /// One bad image is still survivable — the rest of the history must
    /// come back rather than the whole fetch failing.
    @Test("A single failed image doesn't cost the rest of the history")
    @MainActor func testPartialImageFailureSurvives() async throws {
        StubProtocol.reset([
            "lbs/svm/inquire": [(200, inquireBody(ids: [1, 2, 3]))],
            // First image is unusable; the rest resolve.
            "lbs/svm/info": [
                (200, #"{"status":{"statusCode":0,"errorCode":0},"payload":{}}"#),
                (200, infoBody(marker: 0x22))
            ]
        ])

        let captures = try await makeStubbedClient()
            .fetchSurroundViewCaptures(for: makeVehicle(), authToken: stubToken)

        #expect(captures.count == 2)
        #expect(StubProtocol.callCount(forPathSuffix: "lbs/svm/info") == 3)
    }

    // MARK: - Capability declaration

    /// Kia now does both. The two capabilities stay separate because the
    /// gallery shipped months before the trigger was found, and any
    /// future region with the same asymmetry gets the split for free.
    @Test("Kia US advertises both the gallery and the capture trigger")
    @MainActor func testCapabilities() {
        let client = makeClient()
        #expect(client.supportsSurroundView())
        #expect(client.supportsSurroundViewCapture())
    }

    // MARK: - Capture trigger

    /// `lbs/svm/req` was found by probing rather than read anywhere, so
    /// pin down the exact call: the path, and the empty body that
    /// `inquire` also uses.
    @Test("Requesting a capture posts an empty body to lbs/svm/req")
    @MainActor func testRequestCapturePath() async throws {
        StubProtocol.reset([
            "lbs/svm/req": [(200, #"{"status":{"statusCode":0,"errorCode":0}}"#)]
        ])

        try await makeStubbedClient().requestSurroundViewCapture(
            for: makeVehicle(),
            authToken: stubToken
        )

        #expect(StubProtocol.callCount(forPathSuffix: "lbs/svm/req") == 1)
    }

    /// The gap that mattered most once the button went live:
    /// `checkForKiaErrors` only throws for codes it recognises, and the
    /// trigger has no parse step to trip over afterwards. 9000 is
    /// unrecognised — and is exactly what this API answers for a path it
    /// cannot route — so without an explicit success assertion a refused
    /// capture returned as accepted and the app polled for a picture that
    /// was never taken.
    @Test("An unrecognised refusal code still fails the capture request")
    @MainActor func testUnrecognisedRefusalThrows() async {
        StubProtocol.reset([
            "lbs/svm/req": [(200, #"""
            {"status":{"statusCode":1,"errorType":1,"errorCode":9000,
             "errorMessage":"System could not process your request."}}
            """#)]
        ])

        await #expect(throws: APIError.self) {
            try await self.makeStubbedClient().requestSurroundViewCapture(
                for: self.makeVehicle(),
                authToken: self.stubToken
            )
        }
    }

    /// Kia reports refusals inside an HTTP 200 body, so a trigger that was
    /// rejected must not read as accepted — the UI would otherwise sit
    /// waiting for a capture that was never taken.
    @Test("A refused capture request throws")
    @MainActor func testRequestCaptureSurfacesErrors() async {
        StubProtocol.reset([
            "lbs/svm/req": [(200, #"""
            {"status":{"statusCode":1,"errorCode":1005,"errorMessage":"Session expired"}}
            """#)]
        ])

        let error = await #expect(throws: APIError.self) {
            try await self.makeStubbedClient().requestSurroundViewCapture(
                for: self.makeVehicle(),
                authToken: self.stubToken
            )
        }
        #expect(error?.errorType == .invalidVehicleSession)
    }
}
