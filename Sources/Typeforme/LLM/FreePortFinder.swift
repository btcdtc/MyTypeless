import Foundation
import Darwin

enum FreePortFinder {
    enum FinderError: LocalizedError {
        case socketFailed, bindFailed, getsocknameFailed

        var errorDescription: String? {
            switch self {
            case .socketFailed: return "socket() failed when picking a free port"
            case .bindFailed: return "bind() to 127.0.0.1:0 failed"
            case .getsocknameFailed: return "getsockname() failed"
            }
        }
    }

    /// Ask the kernel for an unused TCP port on 127.0.0.1 by binding port 0.
    static func findFreeLocalhostPort() throws -> Int {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw FinderError.socketFailed }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { throw FinderError.bindFailed }

        var resolved = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &resolved) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(sock, sa, &len)
            }
        }
        guard nameOK == 0 else { throw FinderError.getsocknameFailed }

        return Int(UInt16(bigEndian: resolved.sin_port))
    }
}
