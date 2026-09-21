import Foundation

public enum MachineIdentityError: Error, LocalizedError, CustomStringConvertible, Sendable {
    case invalidConfiguration(String)
    case unavailable(String)
    case mismatchedMachine
    case mismatchedKey
    case expiredRegistration

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidConfiguration(let reason): "The machine identity configuration is invalid: \(reason)"
        case .unavailable(let reason): "The machine identity is unavailable: \(reason)"
        case .mismatchedMachine: "The root-owned machine identity belongs to another machine. Replace this machine or its configuration."
        case .mismatchedKey: "The configured machine identity key does not match this machine's root-owned key."
        case .expiredRegistration: "The machine identity registration authority has expired. Rewrite or replace the machine configuration."
        }
    }
}
