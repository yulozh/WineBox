import Foundation
import Network
import SystemConfiguration

/// 获取设备局域网/本地 IP 地址（用于展示 http://192.168.x.x:port）。
enum NetworkService {
    /// 返回本机可用的第一个 IPv4 地址（优先级：WiFi > 蜂窝 > 回环）。
    static func localIPAddress() -> String {
        var result = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let name = String(cString: current.pointee.ifa_name)
            let addr = current.pointee.ifa_addr

            // 只取 IPv4 且非回环
            if addr?.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0,
               name != "lo0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr!.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    // 优先选择 en0（Wi-Fi）
                    if name == "en0" { return ip }
                    if ip != "127.0.0.1" { result = ip }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return result
    }
}