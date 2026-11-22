// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import Darwin

/// Exercises the actual app socket helpers on macOS, without identity files,
/// a remote server, Wi-Fi, a VPN, or a claim that iOS CarPlay has been tested.
@main
enum LocalNetworkSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let queue = DispatchQueue(label: "CarWithin.local-network-smoke")

    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    static func endpoint(_ host: String, _ port: UInt16) throws -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &value.sin_addr) == 1 else { throw Failure(description: "invalid test address") }
        return value
    }

    static func setTimeout(_ fd: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func nonLoopbackAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let host = ReceiverSocketBinding.numericAddress(value)
            if !host.hasPrefix("0."), !host.hasPrefix("127.") { return host }
        }
        return nil
    }

    /// Connects only to another address belonging to this test machine.
    static func requireNonLoopbackRefused(port: UInt16) throws {
        guard let address = nonLoopbackAddress() else {
            print("SKIP: control-port non-loopback rejection (no active local IPv4 interface)")
            return
        }
        let checked = DispatchSemaphore(value: 0)
        var connected = false
        var refused = false
        let connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: connected = true; checked.signal()
            case .waiting(let error):
                // Network.framework may retry a refused connection instead of
                // immediately transitioning to failed. Other path errors are
                // not evidence that the listener is bound only to loopback.
                if case .posix(.ECONNREFUSED) = error { refused = true; checked.signal() }
            case .failed(let error):
                if case .posix(.ECONNREFUSED) = error { refused = true }
                checked.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        defer { queue.sync { connection.cancel() } }
        try require(checked.wait(timeout: .now() + 3) == .success, "non-loopback control-port check did not complete")
        try require(!connected, "control listener accepted a connection through a non-loopback address")
        try require(refused, "non-loopback check failed without an explicit ECONNREFUSED")
        print("PASS: control listener rejected the machine's non-loopback IPv4 address")
    }

    static func tcpRoundTrip(port: UInt16, expected: Data) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try require(fd >= 0, "TCP socket")
        defer { close(fd) }
        setTimeout(fd)
        var target = try endpoint("127.0.0.1", port)
        let connected = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try require(connected == 0, "TCP connect to loopback")
        let sent = expected.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        try require(sent == expected.count, "TCP send")
        var result = Data()
        while result.count < expected.count {
            var bytes = [UInt8](repeating: 0, count: expected.count - result.count)
            let count = recv(fd, &bytes, bytes.count, 0)
            try require(count > 0, "TCP receive")
            result.append(contentsOf: bytes.prefix(count))
        }
        try require(result == expected, "TCP echoed nonce")
    }

    static func testControlBinding() throws {
        let ready = DispatchSemaphore(value: 0)
        let listener = try NWListener(using: ReceiverSocketBinding.parameters(localAddress: "127.0.0.1"), on: .any)
        var accepted: NWConnection?
        listener.newConnectionHandler = { connection in
            accepted = connection
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 12, maximumLength: 12) { bytes, _, _, _ in
                connection.send(content: bytes, completion: .contentProcessed { _ in })
            }
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: queue)
        defer { queue.sync { listener.cancel(); accepted?.cancel() } }
        try require(ready.wait(timeout: .now() + 3) == .success, "control listener startup")
        guard let port = listener.port?.rawValue else { throw Failure(description: "control listener has no port") }
        try tcpRoundTrip(port: port, expected: Data("control-test".utf8))
        try requireNonLoopbackRefused(port: port)
        print("PASS: bound Network.framework control socket round trip")
    }

    static func testMediaTCP() throws {
        let listener = try MediaTCPListener(queue: queue, peerAddress: "127.0.0.1", localAddress: "127.0.0.1")
        var accepted: MediaTCPConnection?
        listener.onConnection = { connection in
            accepted = connection
            connection.onBytes = { [weak connection] bytes in
                if let connection { try connection.send(bytes) }
            }
            connection.start()
        }
        defer { queue.sync { listener.stop(); accepted?.stop() } }
        try require(listener.boundAddress == "127.0.0.1", "media TCP bound to wildcard instead of loopback")
        try tcpRoundTrip(port: listener.port, expected: Data("media-nonce".utf8))
        print("PASS: actual event/video TCP helper bound only to loopback")
    }

    static func udpSocket() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        try require(fd >= 0, "UDP socket")
        setTimeout(fd)
        var address = try endpoint("127.0.0.1", 0)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); throw Failure(description: "UDP bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { close(fd); throw Failure(description: "UDP getsockname") }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    static func sendUDP(_ bytes: Data, fd: Int32, port: UInt16) throws {
        var target = try endpoint("127.0.0.1", port)
        let sent = bytes.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        try require(sent == bytes.count, "UDP send")
    }

    static func testAudioUDP() throws {
        let port = try AudioDatagramPort(queue: queue, peerAddress: "127.0.0.1", localAddress: "127.0.0.1")
        defer { queue.sync { port.stop() } }
        try require(port.boundAddress == "127.0.0.1", "audio UDP bound to wildcard instead of loopback")
        let received = DispatchSemaphore(value: 0)
        let packet = Data("audio-data".utf8)
        port.onPacket = { if $0 == packet { received.signal() } }
        let (fd, _) = try udpSocket()
        defer { close(fd) }
        try sendUDP(packet, fd: fd, port: port.port)
        try require(received.wait(timeout: .now() + 2) == .success, "audio UDP packet not delivered")

        let filtered = try AudioDatagramPort(queue: queue, peerAddress: "127.0.0.2", localAddress: "127.0.0.1")
        defer { queue.sync { filtered.stop() } }
        let rejected = DispatchSemaphore(value: 0)
        filtered.onPacket = { _ in rejected.signal() }
        try sendUDP(packet, fd: fd, port: filtered.port)
        try require(rejected.wait(timeout: .now() + 0.25) == .timedOut, "audio accepted an unexpected peer")
        print("PASS: actual audio UDP helper loopback binding and peer filter")
    }

    static func testTimingUDP() throws {
        let (fd, sourcePort) = try udpSocket()
        defer { close(fd) }
        let timing = try MediaTiming(queue: queue, peerAddress: "127.0.0.1", peerPort: sourcePort, localAddress: "127.0.0.1")
        defer { queue.sync { timing.stop() } }
        try require(timing.boundAddress == "127.0.0.1", "timing UDP bound to wildcard instead of loopback")
        let marker = Data([1, 2, 3, 4, 5, 6, 7, 8])
        try sendUDP(Data([0x80, 210, 0, 7]) + Data(count: 20) + marker, fd: fd, port: timing.port)
        var foundReply = false
        for _ in 0..<3 {
            var buffer = [UInt8](repeating: 0, count: 128)
            let count = recv(fd, &buffer, buffer.count, 0)
            try require(count == 32, "timing reply size")
            if buffer[1] == 211 {
                try require(Data(buffer[8..<16]) == marker, "timing response did not echo request timestamp")
                foundReply = true
                break
            }
        }
        try require(foundReply, "timing response not received")
        print("PASS: actual timing UDP helper loopback request/response")
    }

    static func testProbe(target: String, expected: Bool) throws {
        let completed = DispatchSemaphore(value: 0)
        let probe = LocalReceiverPathProbe(queue: queue, localAddress: "127.0.0.1", targetAddress: target)
        var result = false
        queue.async { probe.start { result = $0; completed.signal() } }
        defer { queue.sync { probe.stop() } }
        try require(completed.wait(timeout: .now() + 4) == .success, "nonce path probe timed out")
        try require(result == expected, "nonce path probe returned incorrect result")
    }

    static func main() throws {
        try testControlBinding()
        try testMediaTCP()
        try testAudioUDP()
        try testTimingUDP()
        try testProbe(target: "127.0.0.1", expected: true)
        try testProbe(target: "127.0.0.2", expected: false)
        print("PASS: nonce probe verifies a return path and rejects a different destination")
        print("Socket tests do not validate the private iOS CarPlay handshake or LocalDevVPN itself.")
    }
}
