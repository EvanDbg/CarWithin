// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TDSCarKitCore

final class ReceiverNetworkModeTests: XCTestCase {
    func testLocalRequestsOmitPreviouslySavedWiFiCredentials() throws {
        for mode in [ReceiverNetworkMode.loopback, .localDevVPN] {
            let address = try XCTUnwrap(mode.sessionAddress)
            let request = try mode.startSession(address: address, port: 51423,
                deviceID: "02:03:04:05:06:07", ssid: "Saved private network",
                password: "saved-passphrase", wifiChannel: 44)
            let wire = try request.encoded()
            let decoded = try IAP2Message.parse(wire)
            XCTAssertEqual(decoded.id, 0x4301)
            XCTAssertNil(decoded.parameters.first { $0.id == 1 }, "Local sessions must not ask iOS to join Wi-Fi")
            XCTAssertNil(wire.range(of: Data("saved-passphrase".utf8)))
            let addressGroup = try IAP2Parameter.parse(XCTUnwrap(decoded.parameters.first { $0.id == 0 }).value)
            XCTAssertEqual(addressGroup.first { $0.id == 0 }?.value, Data((address + "\0").utf8))
            XCTAssertEqual(decoded.parameters.first { $0.id == 2 }?.value, Data([0, 0, 0xc8, 0xdf]))
        }
    }

    func testLocalRequestsDoNotRequireInventedSSIDOrAValidWiFiChannel() throws {
        for mode in [ReceiverNetworkMode.loopback, .localDevVPN] {
            let address = try XCTUnwrap(mode.sessionAddress)
            XCTAssertNoThrow(try mode.startSession(address: address, port: 7000,
                deviceID: "02:03:04:05:06:07", ssid: "", password: "", wifiChannel: 0))
            for invalidTarget in ["0.0.0.0", "192.168.1.23", "203.0.113.7"] {
                XCTAssertThrowsError(try mode.startSession(address: invalidTarget, port: 7000,
                    deviceID: "02:03:04:05:06:07", ssid: "", password: "", wifiChannel: 36))
            }
        }
    }

    func testWiFiModeStillSendsRealWirelessSettings() throws {
        let request = try ReceiverNetworkMode.wifi.startSession(address: "192.168.1.23", port: 7000,
            deviceID: "02:03:04:05:06:07", ssid: "Car network", password: "network-pass", wifiChannel: 36)
        let group = try IAP2Parameter.parse(XCTUnwrap(request.parameters.first { $0.id == 1 }).value)
        XCTAssertEqual(group.first { $0.id == 0 }?.value, Data("Car network\0".utf8))
        XCTAssertEqual(group.first { $0.id == 1 }?.value, Data("network-pass\0".utf8))
        XCTAssertThrowsError(try ReceiverNetworkMode.wifi.startSession(address: "192.168.1.23", port: 7000,
            deviceID: "02:03:04:05:06:07", ssid: "", password: "", wifiChannel: 36))
        XCTAssertNil(ReceiverNetworkMode.wifi.listenerAddress)
    }

    func testVirtualPeerMustNotBeConfusedWithTheTunnelInterface() throws {
        let mode = ReceiverNetworkMode.localDevVPN
        let peer = try XCTUnwrap(mode.sessionAddress)
        let bound = try XCTUnwrap(mode.listenerAddress)
        XCTAssertNotEqual(peer, bound)
        XCTAssertTrue(mode.allowsControlPeer(peer))
        XCTAssertFalse(mode.allowsControlPeer(bound))
        XCTAssertFalse(mode.allowsControlPeer("127.0.0.1"))
        XCTAssertThrowsError(try mode.validateSessionAddress(bound))
        XCTAssertTrue(ReceiverNetworkMode.loopback.allowsControlPeer("127.0.0.1"))
        XCTAssertFalse(ReceiverNetworkMode.loopback.allowsControlPeer("192.168.1.23"))
    }
}
