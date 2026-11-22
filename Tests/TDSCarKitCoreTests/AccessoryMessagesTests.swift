import XCTest
@testable import TDSCarKitCore

final class AccessoryMessagesTests: XCTestCase {
    func testWirelessSessionFieldsPreserveSSID() throws {
        let wifi = try AccessoryMessages.WiFi(ssid: "Test Network", password: "test-passphrase", channel: 44)
        let message = try AccessoryMessages.startSession(address: "10.0.2.126", port: 7000, deviceID: "02:03:04:05:06:07", wifi: wifi)
        let decoded = try IAP2Message.parse(message.encoded())
        let wireless = try IAP2Parameter.parse(XCTUnwrap(decoded.parameters.first { $0.id == 1 }).value)
        XCTAssertEqual(wireless, [
            .init(id: 0, value: Data("Test Network\0".utf8)),
            .init(id: 1, value: Data("test-passphrase\0".utf8)),
            .init(id: 2, value: Data([44])),
            .init(id: 3, value: Data("10.0.2.126\0".utf8)),
            .init(id: 4, value: Data([2]))])
        XCTAssertEqual(decoded.parameters.first { $0.id == 4 }?.value, Data([0]),
                       "A remote receiver's legacy Wi-Fi request may omit its unknown AirPlay key")
    }
    func testOpenNetworkAndInvalidCredentials() throws {
        let message = try AccessoryMessages.startSession(address: "10.0.2.126", port: 7000, deviceID: "02:03:04:05:06:07",
            wifi: .init(ssid: "Open", password: ""))
        let wireless = try IAP2Parameter.parse(XCTUnwrap(message.parameters.first { $0.id == 1 }).value)
        XCTAssertEqual(wireless.first { $0.id == 4 }?.value, Data([0]))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: "", password: ""))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: "Test", password: "short"))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: String(repeating: "é", count: 17), password: ""))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: "Test\0bad", password: ""))
        XCTAssertThrowsError(try AccessoryMessages.WiFi(ssid: "Test", password: "", channel: 0))
    }
    func testSessionPortUsesUInt32EncodingAndNestedAddress() throws {
        let message = try AccessoryMessages.startSession(address: "127.0.0.1", port: 51962, deviceID: "02:03:04:05:06:07",
            airPlayPublicKey: Data(repeating: 0xa5, count: 32))
        let decoded = try IAP2Message.parse(message.encoded())
        XCTAssertEqual(decoded.id, 0x4301)
        let port = try XCTUnwrap(decoded.parameters.first { $0.id == 2 })
        XCTAssertEqual(port.value, Data([0, 0, 0xca, 0xfa]))
        let group = try XCTUnwrap(decoded.parameters.first { $0.id == 0 })
        let address = try IAP2Parameter.parse(group.value)
        XCTAssertEqual(address, [.init(id: 0, value: Data("127.0.0.1\0".utf8))])
        XCTAssertNil(decoded.parameters.first { $0.id == 1 }, "Local mode must not supply invented Wi-Fi credentials")
    }
    func testAirPlayPublicKeyWireEncodingUsesLowercaseHexAndTerminator() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let message = try AccessoryMessages.startSession(address: "127.0.0.1", port: 7000,
            deviceID: "02:03:04:05:06:07", airPlayPublicKey: key)
        let wire = try message.encoded()
        let expectedValue = Data("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\0".utf8)
        // TLV length 69 = 4-byte header + 64 hex characters + one NUL.
        let expectedTLV = Data([0x00, 0x45, 0x00, 0x04]) + expectedValue
        XCTAssertNotNil(wire.range(of: expectedTLV))
        let decoded = try IAP2Message.parse(wire)
        XCTAssertEqual(decoded.parameters.filter { $0.id == 4 }.count, 1)
        XCTAssertEqual(decoded.parameters.first { $0.id == 4 }?.value, expectedValue)
    }
    func testAirPlayPublicKeyRejectsInvalidLengths() throws {
        for count in [0, 1, 31, 33, 64] {
            XCTAssertThrowsError(try AccessoryMessages.startSession(address: "127.0.0.1", port: 7000,
                deviceID: "02:03:04:05:06:07", airPlayPublicKey: Data(repeating: 0xa5, count: count)))
        }
    }
    func testIdentificationTransportIDsAndBluetoothAddress() throws {
        let message = try AccessoryMessages.identification(name: "Test", deviceID: "02:03:04:05:06:07")
        for (groupID, transportID) in [(UInt16(16), UInt8(1)), (17, 2), (24, 3)] {
            let group = try XCTUnwrap(message.parameters.first { $0.id == groupID })
            let values = try IAP2Parameter.parse(group.value)
            XCTAssertEqual(values.first { $0.id == 0 }?.value, Data([0, transportID]))
            if groupID == 17 { XCTAssertEqual(values.first { $0.id == 3 }?.value, Data([2, 3, 4, 5, 6, 7])) }
        }
        XCTAssertThrowsError(try AccessoryMessages.identification(name: "Test", deviceID: "bad"))
    }
}
