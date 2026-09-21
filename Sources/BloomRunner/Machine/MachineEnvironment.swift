import BloomCore
import Foundation

/// Retains ordinary workspace variables and performs one-use scoped secret handoffs. Secret
/// plaintext only crosses this actor in the return value for the exact process being launched.
public actor MachineEnvironment {
    public typealias FetchVariables = @Sendable () async throws -> MachineEnvironmentResponse
    public typealias FetchSecrets = @Sendable (SecretHandoffScope) async throws -> [String: String]

    private let fetchVariables: FetchVariables
    private let fetchSecrets: FetchSecrets
    private(set) public var variables: [String: String] = [:]
    private var fingerprint: Int?
    private var onChange: (@Sendable () async -> Void)?

    public init(fetchVariables: @escaping FetchVariables,
                fetchSecrets: @escaping FetchSecrets = { _ in [:] }) {
        self.fetchVariables = fetchVariables
        self.fetchSecrets = fetchSecrets
    }

    public func observe(_ onChange: @escaping @Sendable () async -> Void) { self.onChange = onChange }

    @discardableResult
    public func refresh() async -> [String: String] {
        do { return try await requiredRefresh() }
        catch { await onChange?(); return variables }
    }

    @discardableResult
    public func requiredRefresh() async throws -> [String: String] {
        let fetched = try await fetchVariables().variables
        let fresh = ProviderCredentialEnvironment.untrustedProcess(fetched)
        var hasher = Hasher()
        for (name, value) in fresh.sorted(by: { $0.key < $1.key }) { hasher.combine(name); hasher.combine(value) }
        let next = hasher.finalize()
        let changed = next != fingerprint
        variables = fresh
        fingerprint = next
        if changed { await onChange?() }
        return variables
    }

    public func scoped(_ scope: SecretHandoffScope, base: [String: String]) async throws -> ScopedProcessEnvironment {
        let secrets = try await fetchSecrets(scope)
        let allowed = ProviderCredentialEnvironment.untrustedProcess(secrets)
        var values = base
        values.merge(allowed) { _, secret in secret }
        return ScopedProcessEnvironment(values: values, redactions: Array(allowed.values))
    }
}
