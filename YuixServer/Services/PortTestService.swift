import Foundation
import Network

/// 端口连通性测试：对任意 host:port 发起一次 TCP 握手，判断端口是否开放。
/// 用来验证本机服务是否真的在监听，或排查局域网内设备的可达性。
enum PortTestService {

    enum ResultKind {
        case open(Double)   // 连通，附带握手耗时（毫秒）
        case closed         // 连接被拒绝或失败：目标可达但没有进程在监听
        case timeout        // 超时无响应：主机不可达或被防火墙静默丢弃
    }

    struct Outcome: Identifiable {
        let id = UUID()
        let host: String
        let port: UInt16
        let result: ResultKind
    }

    static func test(host: String, port: UInt16, timeout: TimeInterval = 3) async -> Outcome {
        await withCheckedContinuation { continuation in
            let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let startedAt = Date()

            let lock = NSLock()
            var resumed = false

            func finish(_ kind: ResultKind) {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                lock.unlock()
                connection.cancel()
                continuation.resume(returning: Outcome(host: host, port: port, result: kind))
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.open(Date().timeIntervalSince(startedAt) * 1000))
                case .failed:
                    finish(.closed)
                default:
                    break
                }
            }
            connection.start(queue: .global())

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.timeout)
            }
        }
    }
}
