//
//  SurroundViewTests.swift
//  BetterBlueKit
//
//  Surround View Monitor decoding and Hyundai Canada payload parsing.
//  Geometry values come from a real Canadian capture: a 4472x720 strip
//  holding four 960-wide fisheye views plus a 632-wide bird's-eye view.
//

import Foundation
import Testing
@testable import BetterBlueKit

@Suite("Surround View")
struct SurroundViewTests {

    /// Bytes that merely *look* like a JPEG — the decoder splits on
    /// markers and never parses the image itself.
    private func fakeJPEG(marker: UInt8, padding: Int = 8) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        data.append(contentsOf: Array(repeating: marker, count: padding))
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }

    // MARK: - Frame extraction

    @Test("A single composite frame comes back whole")
    func testSingleFrame() {
        let frame = fakeJPEG(marker: 0x11)
        let frames = SurroundViewDecoder.extractJPEGFrames(from: frame)

        #expect(frames.count == 1)
        #expect(frames[0] == frame)
    }

    @Test("Concatenated frames are split apart")
    func testConcatenatedFrames() {
        let first = fakeJPEG(marker: 0x11)
        let second = fakeJPEG(marker: 0x22, padding: 12)
        let frames = SurroundViewDecoder.extractJPEGFrames(from: first + second)

        #expect(frames.count == 2)
        #expect(frames[0] == first)
        #expect(frames[1] == second)
    }

    @Test("Trailing padding after the end marker is dropped")
    func testTrailingPaddingTrimmed() {
        let frame = fakeJPEG(marker: 0x11)
        let frames = SurroundViewDecoder.extractJPEGFrames(from: frame + Data([0x00, 0x00, 0x00]))

        #expect(frames == [frame])
    }

    /// An embedded thumbnail carries its own 0xFFD9. Cutting at the first
    /// one would truncate the real image, so frames are split on start
    /// markers instead.
    @Test("An embedded end marker does not truncate the frame")
    func testEmbeddedEndMarkerKeepsFrameIntact() {
        var frame = Data([0xFF, 0xD8, 0xFF, 0xE1])
        frame.append(contentsOf: [0xFF, 0xD9])
        frame.append(contentsOf: Array(repeating: 0x33, count: 32))
        frame.append(contentsOf: [0xFF, 0xD9])

        let frames = SurroundViewDecoder.extractJPEGFrames(from: frame)

        #expect(frames.count == 1)
        #expect(frames[0].count == frame.count)
    }

    @Test("Data without a start marker yields no frames")
    func testNoFrames() {
        #expect(SurroundViewDecoder.extractJPEGFrames(from: Data([0x01, 0x02, 0x03])).isEmpty)
    }

    // MARK: - Tile geometry

    @Test("A 4472x720 strip slices into four cameras plus the top-down view")
    func testCompositeStripTiles() {
        let tiles = SurroundViewDecoder.tiles(
            imageSize: [4472, 720, 960, 720, 632, 720],
            frameCount: 1
        )

        #expect(tiles.map(\.position) == [.front, .rear, .left, .right, .topDown])
        #expect(tiles.allSatisfy { $0.frameIndex == 0 })
        #expect(tiles[0].crop == SurroundViewCrop(x: 0, y: 0, width: 960, height: 720))
        #expect(tiles[3].crop == SurroundViewCrop(x: 2880, y: 0, width: 960, height: 720))
        #expect(tiles[4].crop == SurroundViewCrop(x: 3840, y: 0, width: 632, height: 720))

        // The tiles must exactly cover the strip.
        let covered = tiles.compactMap(\.crop).reduce(0) { $0 + $1.width }
        #expect(covered == 4472)
    }

    @Test("An unrecognized layout falls back to the whole frame")
    func testUnknownLayoutFallsBackToWholeFrame() {
        // Widths that don't divide evenly, and a truncated array: both
        // should still produce something displayable.
        for imageSize in [[4472, 720, 700, 720, 632, 720], [4472, 720]] {
            let tiles = SurroundViewDecoder.tiles(imageSize: imageSize, frameCount: 1)
            #expect(tiles.count == 1)
            #expect(tiles[0].position == .composite)
            #expect(tiles[0].crop == nil)
        }
    }

    @Test("One JPEG per camera needs no slicing")
    func testMultiFrameTiles() {
        let tiles = SurroundViewDecoder.tiles(imageSize: [], frameCount: 4)

        #expect(tiles.map(\.position) == [.front, .rear, .left, .right])
        #expect(tiles.map(\.frameIndex) == [0, 1, 2, 3])
        #expect(tiles.allSatisfy { $0.crop == nil })
    }

    @Test("No frames means no tiles")
    func testNoTilesWithoutFrames() {
        #expect(SurroundViewDecoder.tiles(imageSize: [4472, 720, 960, 720, 632, 720], frameCount: 0).isEmpty)
    }

    // MARK: - Hyundai Canada payload

    @MainActor
    private func makeClient() -> HyundaiCanadaAPIClient {
        HyundaiCanadaAPIClient(configuration: APIClientConfiguration(
            region: .canada,
            brand: .hyundai,
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
            model: "TUCSON",
            accountId: UUID(),
            fuelType: .gas,
            generation: 2,
            odometer: Distance(length: 0, units: .kilometers)
        )
    }

    private func makePayload(entries: [(utcTime: String, marker: UInt8)]) -> Data {
        let locations = entries.map { entry in
            """
            {
              "sidemirrorOpen": true,
              "offset": -5,
              "utcTime": "\(entry.utcTime)",
              "trunkOpen": false,
              "doorOpen": {"frontLeft": 0, "frontRight": 1, "backLeft": 0, "backRight": 0},
              "imageSize": [4472, 720, 960, 720, 632, 720],
              "gpsDetail": {
                "speed": 0, "time": "\(entry.utcTime)", "coordType": 0, "head": 93,
                "coordLat": 43.653226, "coordLon": -79.383184, "speedUnit": 0
              },
              "svmImage": "\(fakeJPEG(marker: entry.marker).base64EncodedString())"
            }
            """
        }.joined(separator: ",")

        return Data("""
        {
          "responseHeader": {"responseDesc": "Success", "responseCode": 0},
          "result": {"svmLocations": [\(locations)]}
        }
        """.utf8)
    }

    @Test("A capture's imagery and metadata are parsed")
    @MainActor func testParsesCapture() throws {
        let captures = try makeClient().parseCanadaSurroundViewResponse(
            makePayload(entries: [(utcTime: "20260826003935", marker: 0x11)]),
            for: makeVehicle()
        )

        let capture = try #require(captures.first)
        #expect(capture.vin == "TESTVIN0000000000")
        #expect(capture.frames.count == 1)
        #expect(capture.tiles.count == 5)
        #expect(capture.heading == 93)
        #expect(capture.sideMirrorOpen == true)
        #expect(capture.trunkOpen == false)
        #expect(capture.doorOpen?.frontRight == true)
        #expect(capture.doorOpen?.frontLeft == false)
        #expect(capture.location?.latitude == 43.653226)
        #expect(capture.location?.longitude == -79.383184)
    }

    /// `utcTime` has no timezone in it — reading it as local time would
    /// shift every capture by the user's offset.
    @Test("utcTime is read as UTC")
    @MainActor func testTimestampIsUTC() throws {
        let captures = try makeClient().parseCanadaSurroundViewResponse(
            makePayload(entries: [(utcTime: "20260826003935", marker: 0x11)]),
            for: makeVehicle()
        )

        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 26
        components.hour = 0
        components.minute = 39
        components.second = 35
        components.timeZone = TimeZone(identifier: "UTC")

        let expected = try #require(Calendar(identifier: .gregorian).date(from: components))
        #expect(captures.first?.capturedAt == expected)
    }

    @Test("Captures are returned newest first")
    @MainActor func testCapturesSortedNewestFirst() throws {
        let captures = try makeClient().parseCanadaSurroundViewResponse(
            makePayload(entries: [
                (utcTime: "20260713192923", marker: 0x11),
                (utcTime: "20260826003935", marker: 0x22),
                (utcTime: "20260806221826", marker: 0x33)
            ]),
            for: makeVehicle()
        )

        #expect(captures.count == 3)
        let timestamps = captures.compactMap(\.capturedAt)
        #expect(timestamps == timestamps.sorted(by: >))
    }

    @Test("An entry with unusable imagery is skipped, not fatal")
    @MainActor func testSkipsUndecodableEntry() throws {
        let payload = Data("""
        {
          "responseHeader": {"responseDesc": "Success", "responseCode": 0},
          "result": {"svmLocations": [{"utcTime": "20260826003935", "svmImage": "bm90LWEtanBlZw=="}]}
        }
        """.utf8)

        #expect(try makeClient().parseCanadaSurroundViewResponse(payload, for: makeVehicle()).isEmpty)
    }

    @Test("A response without svmLocations throws")
    @MainActor func testMissingLocationsThrows() {
        let payload = Data("""
        {"responseHeader": {"responseDesc": "Success", "responseCode": 0}, "result": {}}
        """.utf8)

        #expect(throws: APIError.self) {
            try makeClient().parseCanadaSurroundViewResponse(payload, for: makeVehicle())
        }
    }

    // MARK: - Logging

    /// HTTP logs are persisted, synced, and bundled into debug exports,
    /// so a megabyte of base64 must never reach them.
    @Test("Oversized values are elided from logged bodies")
    func testOversizedValuesElided() throws {
        let image = String(repeating: "A", count: 20_000)
        let body = #"{"utcTime":"20260826003935","svmImage":"\#(image)","head":93}"#

        let elided = try #require(SensitiveDataRedactor.elideOversizedValues(body))

        #expect(!elided.contains(image))
        #expect(elided.contains("20260826003935"))
        #expect(elided.contains("\"head\":93"))
        #expect(elided.contains("20000 characters elided"))
        #expect(try JSONSerialization.jsonObject(with: Data(elided.utf8)) is [String: Any])
    }

    @Test("Ordinary bodies pass through untouched")
    func testSmallBodiesUnchanged() {
        let body = #"{"pin":"1234","escaped":"a \" quote"}"#
        #expect(SensitiveDataRedactor.elideOversizedValues(body) == body)
    }
}
