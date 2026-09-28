import Foundation

/// One drag item reduced to the operations Bloom needs from an `NSItemProvider`.
///
/// The closures keep AppKit out of BloomCore and make the asynchronous boundary fakeable. A file
/// URL is asked for only when the provider advertises one. Image data is asked for only after a
/// concrete supported representation has been chosen, so a provider that also offers arbitrary
/// `Data` never becomes an attachment by accident.
public struct ImageDropProvider: Sendable {
    public var typeIdentifiers: [String]
    public var loadFileURL: @Sendable () async throws -> URL?
    public var loadData: @Sendable (String) async throws -> Data

    public init(
        typeIdentifiers: [String],
        loadFileURL: @escaping @Sendable () async throws -> URL? = { nil },
        loadData: @escaping @Sendable (String) async throws -> Data
    ) {
        self.typeIdentifiers = typeIdentifiers
        self.loadFileURL = loadFileURL
        self.loadData = loadData
    }
}

public enum ImageDropValue: Sendable, Equatable {
    case file(URL)
    case image(Data, PastedImageFormat)
}

public struct ImageDropResult: Sendable, Equatable {
    public struct Loaded: Sendable, Equatable {
        public var index: Int
        public var value: ImageDropValue

        public init(index: Int, value: ImageDropValue) {
            self.index = index
            self.value = value
        }
    }

    public struct Failure: Sendable, Equatable {
        public var index: Int
        public var message: String

        public init(index: Int, message: String) {
            self.index = index
            self.message = message
        }
    }

    public var loaded: [Loaded]
    public var failures: [Failure]

    public init(loaded: [Loaded] = [], failures: [Failure] = []) {
        self.loaded = loaded
        self.failures = failures
    }
}

/// Loads drag providers away from the UI actor while preserving their order and a fixed memory
/// ceiling. Sequential loading is deliberate: retaining several uncompressed TIFF
/// representations at once can otherwise multiply the per-image ceiling by the size of a drag.
public enum ImageDropLoader {
    public enum Failure: LocalizedError, Equatable {
        case unsupported
        case empty
        case tooLarge(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                "That item does not contain a supported image."
            case .empty:
                "That image is empty or could not be read."
            case .tooLarge(let bytes):
                "That image is too large to load (\(bytes) bytes)."
            }
        }
    }

    public static let fileURLType = "public.file-url"
    public static let genericImageType = "public.image"

    public static func canLoad(_ provider: ImageDropProvider) -> Bool {
        provider.typeIdentifiers.contains(fileURLType)
            || PastedImageFormat.best(of: provider.typeIdentifiers) != nil
            || provider.typeIdentifiers.contains(genericImageType)
    }

    public static func load(
        _ providers: [ImageDropProvider],
        maxByteCount: Int
    ) async throws -> ImageDropResult {
        try Task.checkCancellation()
        var result = ImageDropResult()
        var heldBytes = 0
        for (index, provider) in providers.enumerated() where canLoad(provider) {
            do {
                try Task.checkCancellation()
                let value = try await load(provider, maxByteCount: maxByteCount)
                if case .image(let data, _) = value {
                    guard heldBytes <= maxByteCount - data.count else {
                        throw Failure.tooLarge(heldBytes + data.count)
                    }
                    heldBytes += data.count
                }
                result.loaded.append(.init(index: index, value: value))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.failures.append(.init(index: index, message: error.readableMessage))
            }
        }
        return result
    }

    private static func load(
        _ provider: ImageDropProvider,
        maxByteCount: Int
    ) async throws -> ImageDropValue {
        if provider.typeIdentifiers.contains(fileURLType),
           let url = try await provider.loadFileURL(), url.isFileURL {
            return .file(url.standardizedFileURL)
        }

        let advertised = provider.typeIdentifiers
        let format = PastedImageFormat.best(of: advertised)
            ?? (advertised.contains(genericImageType) ? .png : nil)
        guard let format else { throw Failure.unsupported }

        let requestedType = format.providerTypeIdentifiers.first { advertised.contains($0) }
            ?? genericImageType
        let data = try await provider.loadData(requestedType)
        try Task.checkCancellation()
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= maxByteCount else { throw Failure.tooLarge(data.count) }
        let actual = try DroppedImageData.validate(data)
        return .image(data, actual)
    }
}
