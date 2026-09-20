import BloomCore
import BloomProtocol
import Foundation
import HTTPTypes
import Hummingbird

/// Responses in the shapes version 1 promises: JSON bodies, and failures as `{code, message}`.
enum WireResponses {
    static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok, headers: HTTPFields = [:]) -> Response {
        var headers = headers
        headers[.contentType] = "application/json"
        headers[.cacheControl] = "no-store"
        let data = (try? WireJSON.encode(value)) ?? Data("{}".utf8)
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func failure(_ error: WireError, status: HTTPResponse.Status) -> Response {
        json(error, status: status)
    }

    /// The status a refusal travels with. A command's own failures are in a 200 reply; these are
    /// the ones that happen before there is a command to reply to.
    static func status(for error: WireError) -> HTTPResponse.Status {
        switch error.code {
        case .unauthenticated, .tokenExpired: .unauthorized
        case .missingAbility: .forbidden
        case .invalidRequest, .unsupportedVersion: .badRequest
        case .tooLarge: .contentTooLarge
        case .notFound: .notFound
        case .unavailable: .serviceUnavailable
        case .limitReached: .tooManyRequests
        default: .internalServerError
        }
    }

    static func failure(_ error: any Error) -> Response {
        let wire = RemoteFailure.wire(error)
        return failure(wire, status: status(for: wire))
    }
}

extension Request {
    /// The bearer token, and nothing from a cookie or the query: control never reads either, so a
    /// page on the preview's origin cannot act on anybody's behalf.
    var bearerToken: String? {
        guard let header = headers[.authorization] else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
