// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The network path used by the same-device receiver. Both local paths are
/// experimental until the complete CarPlay handshake has succeeded on a device.
public enum ReceiverNetworkMode: String, CaseIterable {
    case wifi
    case loopback
    case localDevVPN

    public var requiresWiFiCredentials: Bool { self == .wifi }
    public var isLocalOnly: Bool { self != .wifi }

    /// The destination sent to iOS in the iAP2 session request.
    public var sessionAddress: String? {
        switch self {
        case .wifi: return nil
        case .loopback: return "127.0.0.1"
        case .localDevVPN: return "10.7.0.1"
        }
    }

    /// LocalDevVPN swaps IPv4 source/destination addresses. Its fake peer
    /// (10.7.0.1) is deliberately different from the actual utun interface.
    public var listenerAddress: String? {
        switch self {
        case .wifi: return nil
        case .loopback: return "127.0.0.1"
        case .localDevVPN: return "10.7.1.1"
        }
    }

    public func allowsControlPeer(_ address: String) -> Bool {
        guard let expected = sessionAddress else { return true }
        return address == expected
    }

    public func validateSessionAddress(_ address: String) throws {
        if let expected = sessionAddress, address != expected {
            throw ProtocolError.malformed("本机模式的 CarPlay 目标必须为 \(expected)")
        }
    }

    /// Uses the existing wire encoder; local modes never include a Wi-Fi TLV,
    /// even if a previously saved SSID/password is still present in the UI.
    /// Local receivers supply their own AirPlay key because discovery is off.
    public func startSession(address: String, port: UInt16, deviceID: String,
                             ssid: String, password: String, wifiChannel: UInt8,
                             airPlayPublicKey: Data? = nil) throws -> IAP2Message {
        try validateSessionAddress(address)
        guard !isLocalOnly || airPlayPublicKey != nil else {
            throw ProtocolError.malformed("本机 CarPlay 会话缺少接收器的 AirPlay 公钥")
        }
        let wifi = try requiresWiFiCredentials
            ? AccessoryMessages.WiFi(ssid: ssid, password: password, channel: wifiChannel)
            : nil
        return try AccessoryMessages.startSession(address: address, port: port, deviceID: deviceID, wifi: wifi,
                                                 airPlayPublicKey: airPlayPublicKey)
    }
}
