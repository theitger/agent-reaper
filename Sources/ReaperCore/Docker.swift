import Darwin
import Foundation

/// Running containers of one compose project (or a lone container).
public struct DockerStack: Sendable, Identifiable {
    public let id: String
    public let containerIDs: [String]
    /// Like `docker stats`: usage minus reclaimable page cache.
    public let memory: UInt64
    /// Cumulative CPU nanoseconds of all containers; idle detection compares
    /// two readings.
    public let cpuNanos: UInt64
    /// Unix seconds of the oldest container.
    public let created: TimeInterval
}

/// Docker Engine API over its Unix socket. One request per connection with
/// `Connection: close`. OrbStack answers chunked even to HTTP/1.0, so the
/// body is de-chunked by hand.
public enum Docker {
    public static func socketPath() -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            home + "/.orbstack/run/docker.sock",
            home + "/.docker/run/docker.sock",
            "/var/run/docker.sock",
        ]
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            candidates.insert(String(host.dropFirst(7)), at: 0)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// nil when no engine is reachable (not installed, VM stopped).
    public static func stacks() -> [DockerStack]? {
        guard let sock = socketPath(),
              let list = request(sock, "GET", "/containers/json") as? [[String: Any]] else { return nil }

        struct Container { let id: String; let project: String; let created: TimeInterval }
        let containers = list.compactMap { c -> Container? in
            guard let id = c["Id"] as? String else { return nil }
            let labels = c["Labels"] as? [String: String] ?? [:]
            let name = ((c["Names"] as? [String])?.first ?? id).trimmingCharacters(in: ["/"])
            return Container(id: id, project: labels["com.docker.compose.project"] ?? name,
                             created: c["Created"] as? TimeInterval ?? 0)
        }

        // one-shot stats answer in ~30 ms; without it each call waits 1 s.
        var stats = [(UInt64, UInt64)](repeating: (0, 0), count: containers.count)
        stats.withUnsafeMutableBufferPointer { out in
            let buffer = out
            DispatchQueue.concurrentPerform(iterations: containers.count) { i in
                let s = request(sock, "GET", "/containers/\(containers[i].id)/stats?stream=false&one-shot=true")
                buffer[i] = parseStats(s as? [String: Any])
            }
        }

        return Dictionary(grouping: containers.indices) { containers[$0].project }
            .map { project, idx in
                DockerStack(
                    id: project,
                    containerIDs: idx.map { containers[$0].id },
                    memory: idx.reduce(0) { $0 + stats[$1].0 },
                    cpuNanos: idx.reduce(0) { $0 + stats[$1].1 },
                    created: idx.map { containers[$0].created }.min() ?? 0
                )
            }
            .sorted { $0.memory > $1.memory }
    }

    static func parseStats(_ s: [String: Any]?) -> (memory: UInt64, cpu: UInt64) {
        let mem = s?["memory_stats"] as? [String: Any]
        let usage = (mem?["usage"] as? NSNumber)?.uint64Value ?? 0
        let cache = ((mem?["stats"] as? [String: Any])?["inactive_file"] as? NSNumber)?.uint64Value ?? 0
        let cpu = ((s?["cpu_stats"] as? [String: Any])?["cpu_usage"] as? [String: Any])?["total_usage"] as? NSNumber
        return (usage > cache ? usage - cache : usage, cpu?.uint64Value ?? 0)
    }

    /// Stops every container of the stack. Blocks up to Docker's stop
    /// timeout per container, so call it off the main thread.
    public static func stop(_ stack: DockerStack) {
        guard let sock = socketPath() else { return }
        DispatchQueue.concurrentPerform(iterations: stack.containerIDs.count) { i in
            _ = request(sock, "POST", "/containers/\(stack.containerIDs[i])/stop", timeout: 30)
        }
    }

    static func request(_ socketPath: String, _ method: String, _ path: String, timeout: Int = 5) -> Any? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard socketPath.utf8.count <= maxLen else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in socketPath.utf8.enumerated() { raw[i] = b }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let req = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        guard req.withCString({ send(fd, $0, strlen($0), 0) }) > 0 else { return nil }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            data.append(chunk, count: n)
        }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).lowercased()
        var body = Data(data[split.upperBound...])
        if head.contains("transfer-encoding: chunked") { body = dechunk(body) }
        return body.isEmpty ? [:] : try? JSONSerialization.jsonObject(with: body)
    }

    /// `<hex size>\r\n<bytes>\r\n` repeated, ending with a zero-size chunk.
    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while let lineEnd = data.range(of: crlf, in: i..<data.endIndex) {
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText.split(separator: ";")[0], radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            guard let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) else { break }
            out.append(data[start..<end])
            i = min(end + 2, data.endIndex)
        }
        return out
    }
}
