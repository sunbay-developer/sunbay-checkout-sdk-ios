import Foundation

/// Device information sent with a payment submission (`userDeviceInfo`).
///
/// Only mobile-relevant fields are present; browser fields, `ip` and `userAgent` are intentionally absent.
struct UserDeviceInfoWire: Encodable, Sendable, Equatable {
    let deviceType: String?
    let deviceModel: String?
    let deviceOs: String?
    let deviceOsVersion: String?
    let deviceResolution: String?
    let screenWidth: String?
    let screenHeight: String?
    let colorDepth: String?
    let timeZoneOffset: String?
    let language: String?
}

/// Collects `UserDeviceInfoWire` using Foundation/Darwin only (no UIKit).
enum DeviceInfoCollector {
    /// Collects device information.
    ///
    /// - Parameter screen: Screen size in points plus scale; supplied by the UI layer. When nil the
    ///   resolution fields are omitted.
    static func collect(screen: (width: Int, height: Int, scale: Double)?) -> UserDeviceInfoWire {
        var width: String?
        var height: String?
        var resolution: String?
        if let screen {
            let pixelWidth = Int((Double(screen.width) * screen.scale).rounded())
            let pixelHeight = Int((Double(screen.height) * screen.scale).rounded())
            width = String(pixelWidth)
            height = String(pixelHeight)
            resolution = "\(pixelWidth)x\(pixelHeight)"
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return UserDeviceInfoWire(
            deviceType: "mobile",
            deviceModel: machineIdentifier(),
            deviceOs: "iOS",
            deviceOsVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            deviceResolution: resolution,
            screenWidth: width,
            screenHeight: height,
            colorDepth: "24",
            timeZoneOffset: String(-TimeZone.current.secondsFromGMT() / 60),
            language: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    /// Returns the hardware identifier (e.g. `iPhone15,2`) from `utsname.machine`.
    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let bytes = withUnsafeBytes(of: &info.machine) { Array($0) }
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        let value = String(decoding: bytes[..<end], as: UTF8.self)
        return value.isEmpty ? "unknown" : value
    }
}
