import Foundation

/// What Bloom tells the browser extension when it cannot do what was asked, so the extension
/// can react rather than carrying on as though it had been done.
enum BrowserExtensionError: LocalizedError {
    case cannotOpenTab
    case cannotShowPopup
    case cannotLoad
    case cannotClose
    case noNativeMessaging

    var errorDescription: String? {
        switch self {
        case .cannotOpenTab: "Bloom could not open a tab for the extension."
        case .cannotLoad: "Bloom does not open that address for the extension."
        case .cannotClose: "Bloom could not close that tab for the extension."
        case .noNativeMessaging: "Native messaging is not available outside Safari."
        case .cannotShowPopup: "Bloom had nowhere on screen to show the extension's popup."
        }
    }
}
