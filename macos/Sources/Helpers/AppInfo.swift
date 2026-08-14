import Foundation

/// True if we appear to be running in Xcode.
func isRunningInXcode() -> Bool {
    ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
}

/// The app's name as a person sees it.
///
/// Read from the bundle rather than written down. A dialog that spelled the
/// name itself is how "Quit Ghostty?" survived into a fork called Phantom:
/// the string had no reason to change when everything visible around it
/// did. Asking the bundle means the next rename cannot leave one behind.
var appDisplayName: String {
    let info = Bundle.main.infoDictionary
    return info?["CFBundleDisplayName"] as? String
        ?? info?["CFBundleName"] as? String
        ?? ProcessInfo.processInfo.processName
}
