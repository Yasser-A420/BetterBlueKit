//
//  SurroundView.swift
//  BetterBlueKit
//
//  Surround View Monitor (SVM) — the 360° camera snapshot a vehicle
//  takes on request and uploads to the brand's servers.
//

import Foundation

// MARK: - Camera Position

/// Which camera a surround-view image came from.
///
/// The payload doesn't label its images, so position is derived from
/// their order: Hyundai returns the fisheye cameras front, rear, left,
/// right, followed by the stitched bird's-eye view.
public enum SurroundViewCameraPosition: String, Codable, Sendable, CaseIterable {
    case front, rear, left, right, topDown, composite

    public var displayName: String {
        switch self {
        case .front: "Front"
        case .rear: "Rear"
        case .left: "Left"
        case .right: "Right"
        case .topDown: "Top"
        case .composite: "Full"
        }
    }
}

// MARK: - Tile Geometry

/// A rectangle inside a JPEG frame, in pixels from the top-left.
public struct SurroundViewCrop: Codable, Sendable, Equatable {
    public let originX: Int, originY: Int, width: Int, height: Int

    public init(originX: Int, originY: Int, width: Int, height: Int) {
        (self.originX, self.originY, self.width, self.height) = (originX, originY, width, height)
    }
}

/// One camera view within a capture: which frame it lives in, and where
/// inside that frame. `crop == nil` means the frame *is* the image.
public struct SurroundViewTile: Codable, Sendable, Equatable, Identifiable {
    public let position: SurroundViewCameraPosition
    public let frameIndex: Int
    public let crop: SurroundViewCrop?

    public var id: String { "\(position.rawValue)@\(frameIndex)" }

    public init(position: SurroundViewCameraPosition, frameIndex: Int, crop: SurroundViewCrop? = nil) {
        self.position = position
        self.frameIndex = frameIndex
        self.crop = crop
    }
}

// MARK: - Capture

/// A single surround-view capture: the images the vehicle took at one
/// moment, plus the context the API reports alongside them.
public struct SurroundViewCapture: Identifiable, Sendable {
    public let vin: String
    /// When the vehicle took the images. Nil when the payload's
    /// timestamp was missing or unparseable.
    public let capturedAt: Date?
    public let location: VehicleStatus.Location?
    /// Vehicle heading in degrees at capture time (0 = north).
    public let heading: Int?
    public let doorOpen: VehicleStatus.DoorStatus?
    public let trunkOpen: Bool?
    public let sideMirrorOpen: Bool?
    /// The JPEG frames the payload carried. Usually one wide composite
    /// strip; some payloads concatenate one JPEG per camera instead.
    public let frames: [Data]
    /// How to read `frames` as individual camera views.
    public let tiles: [SurroundViewTile]

    public var id: String {
        "\(vin)-\(capturedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown")"
    }

    public var isEmpty: Bool { frames.isEmpty }

    /// Total bytes of imagery — used for logging and for deciding what
    /// is safe to keep in memory.
    public var byteCount: Int { frames.reduce(0) { $0 + $1.count } }

    public init(
        vin: String,
        capturedAt: Date?,
        location: VehicleStatus.Location? = nil,
        heading: Int? = nil,
        doorOpen: VehicleStatus.DoorStatus? = nil,
        trunkOpen: Bool? = nil,
        sideMirrorOpen: Bool? = nil,
        frames: [Data],
        tiles: [SurroundViewTile]
    ) {
        self.vin = vin
        self.capturedAt = capturedAt
        self.location = location
        self.heading = heading
        self.doorOpen = doorOpen
        self.trunkOpen = trunkOpen
        self.sideMirrorOpen = sideMirrorOpen
        self.frames = frames
        self.tiles = tiles
    }
}

// Identity-based equality on purpose: the synthesized version would
// byte-compare megabytes of JPEG on every SwiftUI diff.
extension SurroundViewCapture: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.byteCount == rhs.byteCount
    }
}

// MARK: - Decoding

public enum SurroundViewDecoder {
    private static let jpegStart = Data([0xFF, 0xD8, 0xFF])
    private static let jpegEnd = Data([0xFF, 0xD9])

    /// Splits a decoded SVM payload into its JPEG frames.
    ///
    /// The buffer is *usually* a single wide composite, but the format
    /// allows several JPEGs concatenated back to back, so scan for start
    /// markers rather than assuming one image.
    public static func extractJPEGFrames(from data: Data) -> [Data] {
        var starts: [Data.Index] = []
        var searchFrom = data.startIndex
        while let range = data.range(of: jpegStart, in: searchFrom ..< data.endIndex) {
            starts.append(range.lowerBound)
            searchFrom = range.upperBound
        }

        return starts.enumerated().map { index, start in
            // Cut at the NEXT start marker rather than the first end
            // marker: an embedded EXIF thumbnail carries its own
            // 0xFFD9, which would truncate the real image.
            let limit = index + 1 < starts.count ? starts[index + 1] : data.endIndex
            let frame = data[start ..< limit]

            // Drop any padding that follows the frame's own end marker.
            if let end = frame.range(of: jpegEnd, options: .backwards, in: frame.startIndex ..< frame.endIndex) {
                return Data(frame[frame.startIndex ..< end.upperBound])
            }
            return Data(frame)
        }
    }

    /// Works out where each camera view sits, from the payload's
    /// `imageSize` array and the number of frames decoded.
    ///
    /// `imageSize` describes a composite strip as
    /// `[totalW, totalH, cameraW, cameraH, topDownW, topDownH]` — e.g.
    /// `[4472, 720, 960, 720, 632, 720]` is four 960-wide fisheye views
    /// followed by a 632-wide bird's-eye view. Anything that doesn't fit
    /// that shape falls back to "the frame is the image", so an
    /// unfamiliar layout still displays instead of failing.
    public static func tiles(imageSize: [Int], frameCount: Int) -> [SurroundViewTile] {
        guard frameCount > 0 else { return [] }

        guard frameCount == 1 else {
            // One JPEG per camera — nothing to slice.
            return (0 ..< frameCount).map { index in
                SurroundViewTile(position: cameraPosition(at: index), frameIndex: index)
            }
        }

        let wholeFrame = [SurroundViewTile(position: .composite, frameIndex: 0)]

        guard imageSize.count >= 6 else { return wholeFrame }
        let (totalWidth, totalHeight) = (imageSize[0], imageSize[1])
        let (cameraWidth, cameraHeight) = (imageSize[2], imageSize[3])
        let (topDownWidth, topDownHeight) = (imageSize[4], imageSize[5])

        guard totalWidth > 0, totalHeight > 0, cameraWidth > 0, topDownWidth > 0,
              totalWidth > topDownWidth,
              (totalWidth - topDownWidth) % cameraWidth == 0 else {
            return wholeFrame
        }

        let cameraCount = (totalWidth - topDownWidth) / cameraWidth
        guard cameraCount > 0 else { return wholeFrame }

        var tiles: [SurroundViewTile] = (0 ..< cameraCount).map { index in
            SurroundViewTile(
                position: cameraPosition(at: index),
                frameIndex: 0,
                crop: SurroundViewCrop(
                    originX: index * cameraWidth,
                    originY: 0,
                    width: cameraWidth,
                    height: min(cameraHeight, totalHeight)
                )
            )
        }

        tiles.append(SurroundViewTile(
            position: .topDown,
            frameIndex: 0,
            crop: SurroundViewCrop(
                originX: cameraCount * cameraWidth,
                originY: 0,
                width: topDownWidth,
                height: min(topDownHeight, totalHeight)
            )
        ))

        return tiles
    }

    private static func cameraPosition(at index: Int) -> SurroundViewCameraPosition {
        let order: [SurroundViewCameraPosition] = [.front, .rear, .left, .right]
        return index < order.count ? order[index] : .composite
    }
}
