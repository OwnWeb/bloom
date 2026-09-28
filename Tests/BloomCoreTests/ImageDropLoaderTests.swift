import Foundation
import Testing
@testable import BloomCore

@Suite("In-memory image drops")
struct ImageDropLoaderTests {
    private var png: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") ?? Data()
    }

    private func provider(
        _ types: [String],
        file: URL? = nil,
        data: Data? = nil,
        requested: Locked<[String]>? = nil
    ) -> ImageDropProvider {
        ImageDropProvider(
            typeIdentifiers: types,
            loadFileURL: { file },
            loadData: { type in
                requested?.withLock { $0.append(type) }
                return data ?? Data()
            }
        )
    }

    @Test("a CleanShot-style data-only provider becomes an image")
    func dataOnly() async throws {
        let result = try await ImageDropLoader.load(
            [provider(["public.png", "public.image"], data: png)], maxByteCount: 100
        )
        #expect(result.loaded == [.init(index: 0, value: .image(png, .png))])
        #expect(result.failures.isEmpty)
    }

    @Test("a saved file URL keeps using the file path")
    func fileURL() async throws {
        let file = URL(filePath: "/tmp/CleanShot.png")
        let result = try await ImageDropLoader.load([
            provider([ImageDropLoader.fileURLType, "public.png"], file: file, data: png),
        ], maxByteCount: 100)
        #expect(result.loaded == [.init(index: 0, value: .file(file))])
    }

    @Test("the safest concrete representation is chosen deterministically")
    func representationPreference() async throws {
        let requested = Locked<[String]>([])
        _ = try await ImageDropLoader.load([
            provider(
                ["public.tiff", "public.jpeg", "public.heic", "public.png"],
                data: png,
                requested: requested
            ),
        ], maxByteCount: 100)
        #expect(requested.withLock { $0 } == ["public.png"])
    }

    @Test("generic image providers are normalised to PNG")
    func genericImage() async throws {
        let requested = Locked<[String]>([])
        let result = try await ImageDropLoader.load([
            provider([ImageDropLoader.genericImageType], data: png, requested: requested),
        ], maxByteCount: 100)
        #expect(result.loaded == [.init(index: 0, value: .image(png, .png))])
        #expect(requested.withLock { $0 } == [ImageDropLoader.genericImageType])
    }

    @Test("unsupported and arbitrary data providers are ignored")
    func arbitraryData() async throws {
        let result = try await ImageDropLoader.load([
            provider(["public.data"], data: png),
            provider(["public.text"], data: png),
        ], maxByteCount: 100)
        #expect(result.loaded.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test("empty, failed and oversized items do not hide successful neighbours")
    func partialFailure() async throws {
        let providers = [
            provider(["public.png"], data: png),
            provider(["public.jpeg"], data: Data()),
            ImageDropProvider(typeIdentifiers: ["public.heic"]) { _ in
                throw CocoaError(.fileReadCorruptFile)
            },
            provider(["public.tiff"], data: Data(repeating: 1, count: 201)),
            provider(["public.jpeg"], data: png),
        ]
        let result = try await ImageDropLoader.load(providers, maxByteCount: 200)
        #expect(result.loaded.map(\.index) == [0, 4])
        #expect(result.failures.map(\.index) == [1, 2, 3])
    }

    @Test("asynchronous providers preserve drag order")
    func stableOrder() async throws {
        let png = png
        let first = ImageDropProvider(typeIdentifiers: ["public.png"]) { _ in
            try await Task.sleep(for: .milliseconds(30))
            return png
        }
        let second = provider(["public.jpeg"], data: png)
        let result = try await ImageDropLoader.load([first, second], maxByteCount: 200)
        #expect(result.loaded.map(\.index) == [0, 1])
    }

    @Test("invalid and truncated image data are rejected before attachment storage")
    func truncated() async throws {
        let result = try await ImageDropLoader.load([
            provider(["public.png"], data: Data(png.prefix(20))),
            provider(["public.jpeg"], data: Data("not an image".utf8)),
        ], maxByteCount: 100)
        #expect(result.loaded.isEmpty)
        #expect(result.failures.map(\.index) == [0, 1])
    }

    @Test("cancellation reaches provider cleanup and returns no late result")
    func cancellation() async {
        let started = AsyncStream.makeStream(of: Void.self)
        let cancelled = Locked(false)
        let provider = ImageDropProvider(typeIdentifiers: ["public.png"]) { _ in
            started.continuation.yield()
            return try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(60))
                return Data([1])
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }
        let task = Task { try await ImageDropLoader.load([provider], maxByteCount: 100) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelled.withLock { $0 })
        started.continuation.finish()
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
