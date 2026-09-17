import AppKit
@preconcurrency import AppAuth
import BloomClient
import Foundation
import Security

/// The Bloom account this Mac is signed in to, and the access tokens runbloom.app's API takes.
///
/// Ported from #163's `ServerAuthentication`, which signed in to a server of your own with a
/// loopback redirect. runbloom.app is Laravel Passport, which compares redirects exactly, so a
/// loopback redirect carrying a different port each time can never match: the redirect is the app's
/// own scheme instead, `bloom://oauth/callback`, or `bloomdev://oauth/callback` for Bloom Dev, and
/// AppAuth's Mac user agent hands it to `ASWebAuthenticationSession`, which catches the callback
/// itself without the app's URL handler ever seeing it.
///
/// **AppAuth owns the protocol:** PKCE, the code exchange, and refreshing a token that ran out,
/// which runbloom.app rotates on every refresh. This type owns where the result is kept (one
/// keychain item per runbloom.app origin, readable only on this Mac) and signing out, which AppAuth
/// has no call for: RFC 7009 revocation of the refresh token, which revokes both.
@MainActor
public final class BloomAccountSignIn {
    public let environment: RunbloomEnvironment
    private let service: String
    private let session: URLSession
    private var stored: Stored?
    private var hasReadKeychain = false
    private var flow: (any OIDExternalUserAgentSession)?

    /// What is kept: AppAuth's state, which holds the refresh token, and the discovery document it
    /// was issued under, so the API and revocation addresses do not need a request before the first
    /// call after launch.
    private struct Stored {
        var state: OIDAuthState
        var document: BloomAuthDocument
    }

    private struct Archive: Codable {
        var state: Data
        var document: BloomAuthDocument
    }

    public init(environment: RunbloomEnvironment, keychainService: String? = nil, session: URLSession? = nil) {
        self.environment = environment
        service = keychainService ?? (Bundle.main.bundleIdentifier ?? "be.spatie.bloom.dev") + ".account"
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Whether a sign in is kept for this runbloom.app. Reads the keychain once.
    public var isSignedIn: Bool {
        loadIfNeeded()
        return stored?.state.isAuthorized == true
    }

    /// The API root the kept sign in was issued for.
    public var apiBaseURL: URL? {
        loadIfNeeded()
        return stored?.document.apiBaseURL
    }

    // MARK: Signing in

    /// Opens runbloom.app's sign in page in an authentication session over `window`, and keeps the
    /// tokens it ends with.
    public func signIn(presenting window: NSWindow) async throws {
        guard flow == nil else { throw SignInFailure("Signing in is already in progress in another window.") }
        let document = try await discover()
        let client = try document.macClient(redirect: environment.redirect)
        guard let redirect = URL(string: environment.redirect) else { throw SignInFailure("This build of Bloom has no sign in address.") }
        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: document.authorizationEndpoint, tokenEndpoint: document.tokenEndpoint, issuer: document.issuer
        )
        let request = OIDAuthorizationRequest(
            configuration: configuration, clientId: client.clientID, scopes: nil, redirectURL: redirect,
            responseType: OIDResponseTypeCode, additionalParameters: nil
        )
        let agent = OIDExternalUserAgentMac(presenting: window)
        let state: OIDAuthState = try await withCheckedThrowingContinuation { continuation in
            flow = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { state, error in
                if let state {
                    continuation.resume(returning: state)
                } else {
                    continuation.resume(throwing: Self.describe(error, fallback: "Signing in was cancelled."))
                }
            }
        }
        flow = nil
        let kept = Stored(state: state, document: document)
        try save(kept)
        stored = kept
    }

    /// Stops a sign in that is waiting on the browser sheet.
    public func cancelSignIn() {
        flow?.cancel()
        flow = nil
    }

    // MARK: Tokens

    /// An access token, refreshed first when it ran out or when `forceRefresh` says the last one was
    /// refused. A refresh runbloom.app refuses ends the sign in: the keychain item goes, so the app
    /// shows its signed out state rather than failing every request after.
    public func accessToken(forceRefresh: Bool) async throws -> String {
        loadIfNeeded()
        guard let stored, stored.state.isAuthorized else { throw SignInFailure.signedOut }
        if forceRefresh { stored.state.setNeedsTokenRefresh() }
        do {
            let token: String = try await withCheckedThrowingContinuation { continuation in
                stored.state.performAction { token, _, error in
                    if let token {
                        continuation.resume(returning: token)
                    } else {
                        continuation.resume(throwing: error ?? SignInFailure.signedOut)
                    }
                }
            }
            try? save(stored)
            return token
        } catch let error as NSError where error.domain == OIDOAuthTokenErrorDomain {
            forget()
            throw SignInFailure.signedOut
        } catch {
            throw Self.describe(error, fallback: "runbloom.app could not be reached.")
        }
    }

    // MARK: Signing out

    /// Revokes the tokens on runbloom.app and forgets them here. The keychain item goes whether or
    /// not runbloom.app could be reached, because signing out on this Mac is what was asked; a token
    /// runbloom.app never heard about expires by itself.
    public func signOut() async {
        loadIfNeeded()
        guard let stored else { return }
        let token = stored.state.refreshToken ?? stored.state.lastTokenResponse?.accessToken
        let client = try? stored.document.macClient(redirect: environment.redirect)
        forget()
        guard let token, let client, let endpoint = stored.document.revocationEndpoint else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form([
            "client_id": client.clientID, "token": token,
            "token_type_hint": stored.state.refreshToken == nil ? "access_token" : "refresh_token",
        ])
        _ = try? await session.data(for: request)
    }

    private func forget() {
        stored = nil
        SecItemDelete(query() as CFDictionary)
    }

    // MARK: Discovery

    private func discover() async throws -> BloomAuthDocument {
        var request = URLRequest(url: BloomAuthDocument.url(for: environment.origin))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.describe(error, fallback: "runbloom.app could not be reached.")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 65_536 else {
            throw SignInFailure("runbloom.app does not offer sign in right now.")
        }
        guard let document = try? JSONDecoder().decode(BloomAuthDocument.self, from: data) else {
            throw SignInFailure("runbloom.app's sign in details could not be read by this version of Bloom.")
        }
        try document.validate(origin: environment.origin)
        return document
    }

    // MARK: Keychain

    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: environment.origin.absoluteString,
        ]
    }

    private func loadIfNeeded() {
        guard !hasReadKeychain else { return }
        hasReadKeychain = true
        var query = query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archive.state) else { return }
        stored = Stored(state: state, document: archive.document)
    }

    private func save(_ stored: Stored) throws {
        let state = try NSKeyedArchiver.archivedData(withRootObject: stored.state, requiringSecureCoding: true)
        let data = try JSONEncoder().encode(Archive(state: state, document: stored.document))
        var status = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query()
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Bloom account"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SignInFailure("Your Bloom account could not be saved in the keychain.") }
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    private static func describe(_ error: (any Error)?, fallback: String) -> SignInFailure {
        guard let error = error as NSError? else { return SignInFailure(fallback) }
        if error.domain == OIDGeneralErrorDomain, error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue {
            return SignInFailure("Signing in was cancelled.", isCancellation: true)
        }
        if error.domain == NSURLErrorDomain { return SignInFailure("runbloom.app could not be reached. \(error.localizedDescription)") }
        if error.domain == OIDOAuthAuthorizationErrorDomain || error.domain == OIDOAuthTokenErrorDomain {
            return SignInFailure("runbloom.app refused the sign in. \(error.localizedDescription)")
        }
        return SignInFailure(fallback)
    }
}

/// Why signing in, or asking for a token, did not work, as a sentence.
public struct SignInFailure: Error, Sendable, Hashable, LocalizedError {
    public var message: String
    public var isCancellation: Bool

    public init(_ message: String, isCancellation: Bool = false) {
        self.message = message
        self.isCancellation = isCancellation
    }

    public static let signedOut = SignInFailure("Sign in to your Bloom account to use Cloud workspaces.")

    public var errorDescription: String? { message }
}
