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
    /// Empty until the imagery has been fetched — see `isLoaded`.
    public let frames: [Data]
    /// How to read `frames` as individual camera views.
    public let tiles: [SurroundViewTile]
    /// The brand's own identifier for this capture, when it has one, used
    /// to request the imagery separately.
    ///
    /// Only regions that bill imagery per capture set this. Hyundai
    /// returns every image inline with the list, so its captures arrive
    /// loaded and carry no provider id; Kia lists captures with
    /// `lbs/svm/inquire` and fetches each `svmId` through `lbs/svm/info`.
    public let providerID: String?

    public var id: String {
        "\(vin)-\(capturedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown")"
    }

    /// Whether this capture's imagery has actually been fetched.
    ///
    /// A capture can exist as metadata alone — timestamp, location,
    /// heading — while its images are still on the server. Callers that
    /// need pixels should load it first (see
    /// `APIClientProtocol.fetchSurroundViewImagery`); callers that only
    /// need to list or order captures can use it as it is.
    public var isLoaded: Bool { !frames.isEmpty }

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
        tiles: [SurroundViewTile],
        providerID: String? = nil
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
        self.providerID = providerID
    }

    /// The same capture with imagery attached. Everything else is
    /// carried over, so metadata read from a listing survives a load that
    /// reports less than the listing did.
    public func loaded(frames: [Data], tiles: [SurroundViewTile]) -> SurroundViewCapture {
        SurroundViewCapture(
            vin: vin,
            capturedAt: capturedAt,
            location: location,
            heading: heading,
            doorOpen: doorOpen,
            trunkOpen: trunkOpen,
            sideMirrorOpen: sideMirrorOpen,
            frames: frames,
            tiles: tiles,
            providerID: providerID
        )
    }
}

// Identity-based equality on purpose: the synthesized version would
// byte-compare megabytes of JPEG on every SwiftUI diff.
extension SurroundViewCapture: Equatable {
    // byteCount is part of it so a placeholder and its loaded form differ,
    // which is what makes SwiftUI redraw when imagery arrives.
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

    // MARK: - Geometry inference

    /// The composite layout every region observed so far produces: four
    /// fisheye panels followed by a narrower bird's-eye, all the full
    /// height of the strip.
    ///
    /// Hyundai states it in `imageSize`. Kia sends no such field, but a
    /// real Kia capture measures **4472×720** — identical — and Kia's own
    /// app bundles debug frames at exactly 960×720 and 632×720, the panel
    /// sizes below. So this is a confirmed layout shared across brands,
    /// not a guess extrapolated from one of them.
    private static let referenceStrip = (width: 4472, height: 720, camera: 960, topDown: 632)

    /// How far a strip's aspect ratio may drift from the reference and
    /// still be treated as the same layout. Tight on purpose: a payload
    /// that is genuinely shaped differently must fall back to
    /// "the frame is the image" rather than be cropped into nonsense.
    private static let aspectTolerance = 0.01

    /// Reads a JPEG's pixel dimensions from its start-of-frame header.
    ///
    /// Walks the marker segments rather than decoding — no image
    /// framework, so this works identically on watchOS. Returns nil for
    /// anything that isn't a JPEG whose header can be read, which is the
    /// signal to fall back rather than to fail.
    public static func pixelSize(ofJPEG data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else {
                index += 1
                continue
            }

            let marker = bytes[index + 1]
            // Fill bytes, and the standalone markers that carry no length.
            if marker == 0xFF {
                index += 1
                continue
            }
            if marker == 0x01 || (0xD0 ... 0xD9).contains(marker) {
                index += 2
                continue
            }

            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { return nil }

            // SOF0…SOF15 carry the frame size. C4/C8/CC are DHT/JPG/DAC,
            // which share the range but describe something else.
            if (0xC0 ... 0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                guard index + 8 < bytes.count else { return nil }
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                guard width > 0, height > 0 else { return nil }
                return (width, height)
            }

            index += 2 + length
        }

        return nil
    }

    /// Rebuilds the `imageSize` a payload didn't send, from the strip's
    /// own pixel dimensions.
    ///
    /// Only answers when the aspect ratio matches the reference layout, so
    /// an unfamiliar composite stays whole instead of being sliced on a
    /// guess. The bird's-eye width is taken as the REMAINDER rather than
    /// scaled independently, which guarantees the result satisfies
    /// `tiles(imageSize:frameCount:)`'s divisibility check exactly even
    /// when scaling rounds.
    public static func inferredImageSize(width: Int, height: Int) -> [Int]? {
        guard width > 0, height > 0 else { return nil }

        let reference = Double(referenceStrip.width) / Double(referenceStrip.height)
        let actual = Double(width) / Double(height)
        guard abs(actual - reference) / reference <= aspectTolerance else { return nil }

        let scale = Double(height) / Double(referenceStrip.height)
        let cameraWidth = Int((Double(referenceStrip.camera) * scale).rounded())
        guard cameraWidth > 0 else { return nil }

        let topDownWidth = width - cameraWidth * 4
        guard topDownWidth > 0 else { return nil }

        return [width, height, cameraWidth, height, topDownWidth, height]
    }

    /// Works out the tiling for a capture, falling back to the strip's own
    /// dimensions when the payload carried no `imageSize`.
    ///
    /// This is what lets a region that reports no geometry — Kia — still
    /// get its five camera views instead of one unreadable 6:1 strip.
    public static func tiles(imageSize: [Int], frames: [Data]) -> [SurroundViewTile] {
        if imageSize.count >= 6 {
            return tiles(imageSize: imageSize, frameCount: frames.count)
        }

        guard frames.count == 1,
              let size = pixelSize(ofJPEG: frames[0]),
              let inferred = inferredImageSize(width: size.width, height: size.height) else {
            return tiles(imageSize: imageSize, frameCount: frames.count)
        }

        return tiles(imageSize: inferred, frameCount: frames.count)
    }

    private static func cameraPosition(at index: Int) -> SurroundViewCameraPosition {
        let order: [SurroundViewCameraPosition] = [.front, .rear, .left, .right]
        return index < order.count ? order[index] : .composite
    }
}
