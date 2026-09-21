import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Validates provider bytes without decoding their pixels. This keeps malformed and hostile image
/// payloads out of attachment storage while avoiding the memory cost of constructing an image.
public enum DroppedImageData {
    public enum Failure: LocalizedError, Equatable {
        case invalid
        case unsupported(String)
        case dimensions(Int, Int)

        public var errorDescription: String? {
            switch self {
            case .invalid:
                "That image is incomplete or could not be read."
            case .unsupported(let type):
                "Bloom does not support dropped images of type \(type)."
            case .dimensions(let width, let height):
                "That image is too large to decode safely (\(width) by \(height) pixels)."
            }
        }
    }

    /// A ceiling on decoded pixels, not encoded bytes. The byte ceiling catches large files; this
    /// one catches a tiny header that claims an image large enough to exhaust memory when previewed.
    public static let maxPixelCount = 100_000_000

    public static func validate(_ data: Data) throws -> PastedImageFormat {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let identifier = CGImageSourceGetType(source) as String?
        else { throw Failure.invalid }

        let format: PastedImageFormat
        switch identifier {
        case "public.png": format = .png
        case "public.jpeg": format = .jpeg
        case "public.heic": format = .heic
        case "public.heif": format = .heif
        case "public.tiff": format = .tiff
        default: throw Failure.unsupported(identifier)
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw Failure.invalid }
        guard width <= maxPixelCount / height else { throw Failure.dimensions(width, height) }
        return format
        #else
        throw Failure.unsupported("image")
        #endif
    }
}
