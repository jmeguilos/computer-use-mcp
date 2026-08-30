import CoreGraphics
import Foundation

public struct ScreenshotSizingPolicy: Codable, Equatable, Sendable {
    public let maxDimension: Int
    public let maxPixels: Int
    public let allowUpscale: Bool

    public let maximumDecodedBytes: Int

    public init(
        maxDimension: Int = 2_048,
        maxPixels: Int = 4_000_000,
        maximumDecodedBytes: Int = 5 * 1_024 * 1_024,
        allowUpscale: Bool = false
    ) {
        self.maxDimension = maxDimension
        self.maxPixels = maxPixels
        self.maximumDecodedBytes = maximumDecodedBytes
        self.allowUpscale = allowUpscale
    }
}

/// Row-vector-free affine contract used on the wire. Coordinates are mapped as
/// `x' = m11*x + m21*y + tx`, `y' = m12*x + m22*y + ty`.
public struct AffineTransform2D: Codable, Equatable, Sendable {
    public let m11: Double
    public let m12: Double
    public let m21: Double
    public let m22: Double
    public let tx: Double
    public let ty: Double

    public init(m11: Double, m12: Double, m21: Double, m22: Double, tx: Double, ty: Double) {
        self.m11 = m11
        self.m12 = m12
        self.m21 = m21
        self.m22 = m22
        self.tx = tx
        self.ty = ty
    }

    public func applying(to point: Point) -> Point {
        Point(
            x: m11 * point.x + m21 * point.y + tx,
            y: m12 * point.x + m22 * point.y + ty
        )
    }
}

public struct ScreenshotTransform: Codable, Equatable, Sendable {
    public let sourceSize: Size
    public let outputSize: Size
    public let globalOrigin: Point
    public let sourcePointsPerOutputPixel: Point
    public let imageToGlobal: AffineTransform2D
    public let globalToImage: AffineTransform2D

    public init(sourceSize: Size, outputSize: Size, globalOrigin: Point) throws {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              outputSize.width.isFinite, outputSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            throw ScreenshotTransformError.invalidDimensions
        }
        self.sourceSize = sourceSize
        self.outputSize = outputSize
        self.globalOrigin = globalOrigin
        self.sourcePointsPerOutputPixel = Point(
            x: sourceSize.width / outputSize.width,
            y: sourceSize.height / outputSize.height
        )
        let sx = sourceSize.width / outputSize.width
        let sy = sourceSize.height / outputSize.height
        self.imageToGlobal = AffineTransform2D(
            m11: sx, m12: 0, m21: 0, m22: sy,
            tx: globalOrigin.x, ty: globalOrigin.y
        )
        self.globalToImage = AffineTransform2D(
            m11: 1 / sx, m12: 0, m21: 0, m22: 1 / sy,
            tx: -globalOrigin.x / sx, ty: -globalOrigin.y / sy
        )
    }

    public func globalPoint(forOutputPoint point: Point) throws -> Point {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < outputSize.width, point.y < outputSize.height else {
            throw ScreenshotTransformError.pointOutsideOutput
        }
        return imageToGlobal.applying(to: point)
    }

    public func outputPoint(forGlobalPoint point: Point) throws -> Point {
        let result = globalToImage.applying(to: point)
        guard result.x.isFinite, result.y.isFinite,
              result.x >= 0, result.y >= 0,
              result.x < outputSize.width, result.y < outputSize.height else {
            throw ScreenshotTransformError.pointOutsideSource
        }
        return result
    }

    public func replacingOutputSize(_ size: Size) throws -> ScreenshotTransform {
        try ScreenshotTransform(sourceSize: sourceSize, outputSize: size, globalOrigin: globalOrigin)
    }

    public static func make(
        sourceSize: Size,
        globalOrigin: Point,
        policy: ScreenshotSizingPolicy = ScreenshotSizingPolicy()
    ) throws -> ScreenshotTransform {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              policy.maxDimension > 0, policy.maxPixels > 0, policy.maximumDecodedBytes > 0 else {
            throw ScreenshotTransformError.invalidDimensions
        }

        let dimensionFactor = Double(policy.maxDimension) / max(sourceSize.width, sourceSize.height)
        let pixelFactor = sqrt(Double(policy.maxPixels) / (sourceSize.width * sourceSize.height))
        let upperBound = policy.allowUpscale ? Double.greatestFiniteMagnitude : 1.0
        let scale = min(upperBound, dimensionFactor, pixelFactor)
        let width = max(1, floor(sourceSize.width * scale))
        let height = max(1, floor(sourceSize.height * scale))
        return try ScreenshotTransform(
            sourceSize: sourceSize,
            outputSize: Size(width: width, height: height),
            globalOrigin: globalOrigin
        )
    }
}

public enum ScreenshotTransformError: String, Error, Codable, Equatable, Sendable {
    case invalidDimensions
    case pointOutsideOutput
    case pointOutsideSource
}

public struct ScreenshotPayload: Codable, Equatable, Sendable {
    public let mimeType: String
    public let data: String
    public let width: Int
    public let height: Int
    public let sha256: String
    public let transform: ScreenshotTransform
    public let decodedByteCount: Int

    public init(
        mimeType: String,
        data: String,
        width: Int,
        height: Int,
        sha256: String,
        transform: ScreenshotTransform,
        decodedByteCount: Int
    ) {
        self.mimeType = mimeType
        self.data = data
        self.width = width
        self.height = height
        self.sha256 = sha256
        self.transform = transform
        self.decodedByteCount = decodedByteCount
    }
}

public struct OverlayPlacement: Equatable, Sendable {
    public let frame: Rect
    public let railWidth: Double

    public init(frame: Rect, railWidth: Double) {
        self.frame = frame
        self.railWidth = railWidth
    }

    public static func leftEdge(
        targetTopLeftFrame: Rect,
        displayTopLeftFrame: Rect,
        panelSize: Size = Size(width: 176, height: 48),
        railWidth: Double = 8,
        gap: Double = 6
    ) -> OverlayPlacement {
        let display = displayTopLeftFrame.cgRect
        let target = targetTopLeftFrame.cgRect
        var x = target.minX - panelSize.width - gap
        if x < display.minX {
            x = max(display.minX, target.minX)
        }
        let desiredY = target.minY + min(32, max(0, target.height - panelSize.height) / 2)
        let y = min(max(desiredY, display.minY), max(display.minY, display.maxY - panelSize.height))
        return OverlayPlacement(
            frame: Rect(origin: Point(x: x, y: y), size: panelSize),
            railWidth: railWidth
        )
    }
}
