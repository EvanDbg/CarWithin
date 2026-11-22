import Foundation
import Darwin
import Network

/// Shared by the actual control, media and microphone sockets. A nil address
/// preserves the existing Wi-Fi listener; local modes always supply an IPv4.
enum ReceiverSocketBinding {
    static func apply(_ localAddress: String?, to address: inout sockaddr_in) throws {
        guard let localAddress else { return }
        guard inet_pton(AF_INET, localAddress, &address.sin_addr) == 1 else {
            throw ProtocolError.malformed("接收器本地绑定地址必须为 IPv4")
        }
    }

    static func numericAddress(_ address: in_addr) -> String {
        var address = address
        var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &bytes, socklen_t(bytes.count)) != nil else { return "" }
        return String(cString: bytes)
    }

    static func ipv4Peer(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        if case .ipv4(let address) = host {
            // Do not compare a scoped/debug host description with a numeric IP.
            return address.rawValue.map { String($0) }.joined(separator: ".")
        }
        var parsed = in_addr()
        guard inet_pton(AF_INET, "\(host)", &parsed) == 1 else { return nil }
        return numericAddress(parsed)
    }

    static func parameters(localAddress: String?, port: NWEndpoint.Port = .any, udp: Bool = false) throws -> NWParameters {
        let parameters = udp ? NWParameters.udp : NWParameters.tcp
        if let localAddress {
            guard IPv4Address(localAddress) != nil else {
                throw ProtocolError.malformed("接收器本地绑定地址必须为 IPv4")
            }
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localAddress), port: port)
        }
        return parameters
    }
}

/// A short nonce round trip verifies that a requested virtual peer really
/// returns packets to this app. This does not test the iOS CarPlay subsystem.
/// All methods and callbacks run on the supplied serial queue.
final class LocalReceiverPathProbe {
    private let queue: DispatchQueue
    private let localAddress: String
    private let targetAddress: String
    private let nonce = Data(UUID().uuidString.utf8)
    private var listener: NWListener?
    private var client: NWConnection?
    private var accepted: NWConnection?
    private var timeout: DispatchWorkItem?
    private var completion: ((Bool) -> Void)?

    init(queue: DispatchQueue, localAddress: String, targetAddress: String) {
        self.queue = queue; self.localAddress = localAddress; self.targetAddress = targetAddress
    }

    func start(completion: @escaping (Bool) -> Void) {
        stop(); self.completion = completion
        do {
            let parameters = try ReceiverSocketBinding.parameters(localAddress: localAddress)
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.completion != nil, self.accepted == nil,
                      ReceiverSocketBinding.ipv4Peer(connection.endpoint) == self.targetAddress else { connection.cancel(); return }
                self.accepted = connection
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: self.nonce.count, maximumLength: self.nonce.count) { [weak self, weak connection] bytes, _, _, error in
                    guard let self, let connection, self.completion != nil else { return }
                    guard error == nil, bytes == self.nonce else { self.finish(false); return }
                    connection.send(content: self.nonce, completion: .contentProcessed { [weak self] error in
                        if error != nil { self?.finish(false) }
                    })
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.completion != nil else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { self.finish(false); return }
                    self.connect(port: port)
                case .failed: self.finish(false)
                default: break
                }
            }
            let timeout = DispatchWorkItem { [weak self] in self?.finish(false) }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + 3, execute: timeout)
            listener.start(queue: queue)
        } catch { finish(false) }
    }

    private func connect(port: NWEndpoint.Port) {
        do {
            let parameters = try ReceiverSocketBinding.parameters(localAddress: localAddress)
            let client = NWConnection(host: NWEndpoint.Host(targetAddress), port: port, using: parameters)
            self.client = client
            client.stateUpdateHandler = { [weak self, weak client] state in
                guard let self, let client, self.completion != nil else { return }
                switch state {
                case .ready:
                    client.send(content: self.nonce, completion: .contentProcessed { [weak self] error in
                        if error != nil { self?.finish(false) }
                    })
                    client.receive(minimumIncompleteLength: self.nonce.count, maximumLength: self.nonce.count) { [weak self] bytes, _, _, error in
                        guard let self else { return }
                        self.finish(error == nil && bytes == self.nonce)
                    }
                case .failed: self.finish(false)
                default: break
                }
            }
            client.start(queue: queue)
        } catch { finish(false) }
    }

    private func finish(_ success: Bool) {
        let completion = self.completion
        stop()
        completion?(success)
    }

    func stop() {
        completion = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        client?.cancel(); client = nil
        accepted?.cancel(); accepted = nil
    }
    deinit { stop() }
}

/// Queue-confined socket helpers. Ports are bound synchronously before SETUP replies.
final class MediaTCPListener {
    let port: UInt16
    let boundAddress: String
    private var source: DispatchSourceRead?
    var onConnection: ((MediaTCPConnection) -> Void)?
    init(queue: DispatchQueue, peerAddress: String, localAddress: String? = nil) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        var allowed = in_addr()
        guard inet_pton(AF_INET, peerAddress, &allowed) == 1 else { close(fd); throw ProtocolError.malformed("需要 IPv4 媒体对端地址") }
        do { try ReceiverSocketBinding.apply(localAddress, to: &address) }
        catch { close(fd); throw error }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 2) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard named == 0 else { close(fd); throw POSIXError(.EIO) }
        port = UInt16(bigEndian: address.sin_port)
        boundAddress = ReceiverSocketBinding.numericAddress(address.sin_addr)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var remote = sockaddr_in(); var count = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &count) } }
            guard client >= 0 else { return }
            guard remote.sin_addr.s_addr == allowed.s_addr, let callback = self.onConnection else { close(client); return }
            callback(MediaTCPConnection(fd: client, queue: queue))
        }
        source.setCancelHandler { close(fd) }; source.resume()
    }
    func stop() { source?.cancel(); source = nil; onConnection = nil }
    deinit { stop() }
}

final class MediaTCPConnection {
    private let io: DispatchIO
    private let queue: DispatchQueue
    private var pending = 0
    private var stopped = false
    var onBytes: ((Data) throws -> Void)?
    var onClose: (() -> Void)?
    init(fd: Int32, queue: DispatchQueue) {
        self.queue = queue
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Touch and HID reports are tiny; Nagle would hold them back behind unacknowledged data.
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        io.setLimit(lowWater: 1); io.setLimit(highWater: 65536)
    }
    func start() {
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self, !self.stopped else { return }
            do { if let data, !data.isEmpty { try self.onBytes?(Data(data)) } }
            catch { self.stop(); self.onClose?(); return }
            if done || error != 0 { self.stop(); self.onClose?() }
        }
    }
    func send(_ data: Data) throws {
        guard !stopped, pending + data.count <= 256 * 1024 else { throw ProtocolError.limitExceeded("事件输出队列") }
        pending += data.count
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: bytes, queue: queue) { [weak self] done, _, error in
            guard let self else { return }
            if done { self.pending -= data.count }
            if error != 0 { self.stop(); self.onClose?() }
        }
    }
    func stop() { guard !stopped else { return }; stopped = true; io.close(flags: .stop); onBytes = nil }
    deinit { stop() }
}

final class MediaTiming {
    let port: UInt16
    let boundAddress: String
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var pending: Data?
    private var offset: Double = 0
    private let origin = Date().timeIntervalSince1970 + 2_208_988_800
    private let monotonic = ProcessInfo.processInfo.systemUptime
    private func now() -> Double { origin + ProcessInfo.processInfo.systemUptime - monotonic + offset }
    func timestamp() -> UInt64 { Self.encode(now()).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    private static func encode(_ time: Double) -> Data {
        let seconds = UInt64(time.rounded(.down)), fraction = UInt64((time - time.rounded(.down)) * 4_294_967_296)
        let value = (seconds << 32) | fraction
        return Data(stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) })
    }
    private static func decode(_ bytes: Data) -> Double {
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Double(value >> 32) + Double(value & 0xffffffff) / 4_294_967_296
    }
    init(queue: DispatchQueue, peerAddress: String, peerPort: UInt16, localAddress: String? = nil) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var remote = sockaddr_in(); remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); remote.sin_family = sa_family_t(AF_INET); remote.sin_port = peerPort.bigEndian
        guard inet_pton(AF_INET, peerAddress, &remote.sin_addr) == 1 else { close(fd); throw ProtocolError.malformed("时钟同步对端地址") }
        var local = sockaddr_in(); local.sin_len = remote.sin_len; local.sin_family = remote.sin_family
        do { try ReceiverSocketBinding.apply(localAddress, to: &local) }
        catch { close(fd); throw error }
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard named == 0 else { close(fd); throw POSIXError(.EIO) }
        port = UInt16(bigEndian: local.sin_port)
        boundAddress = ReceiverSocketBinding.numericAddress(local.sin_addr)
        let send: (Data) -> Void = { data in
            data.withUnsafeBytes { bytes in
                _ = withUnsafePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue); self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 2048), peer = sockaddr_in(); var count = socklen_t(MemoryLayout<sockaddr_in>.size)
            let length = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, bytes.count, 0, $0, &count) } }
            guard length == 32, peer.sin_addr.s_addr == remote.sin_addr.s_addr, peer.sin_port == remote.sin_port else { return }
            let message = Data(bytes.prefix(length))
            if bytes[1] == 210 {
                var response = Data([0x80, 211, 0, 7]) + Data(count: 4)
                response += message.suffix(8); response += Self.encode(self.now()); response += Self.encode(self.now()); send(response)
            } else if bytes[1] == 211, let pending = self.pending, message.subdata(in: 8..<16) == pending {
                let t1 = Self.decode(pending), t2 = Self.decode(message.subdata(in: 16..<24)), t3 = Self.decode(message.suffix(8)), t4 = self.now()
                let rtt = (t4 - t1) - (t3 - t2)
                if rtt >= 0, rtt < 1 { self.offset += ((t2 - t1) + (t3 - t4)) / 2 }
                self.pending = nil
            }
        }
        source.setCancelHandler { close(fd) }; source.resume()
        if peerPort != 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let stamp = Self.encode(self.now()); self.pending = stamp
                send(Data([0x80, 210, 0, 7]) + Data(count: 20) + stamp)
            }
            timer.resume()
        }
    }
    func stop() { timer?.cancel(); timer = nil; source?.cancel(); source = nil }
    deinit { stop() }
}
