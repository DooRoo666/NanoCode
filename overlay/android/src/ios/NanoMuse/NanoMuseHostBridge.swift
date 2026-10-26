import Foundation

/// 宿主文件桥：给 Linux 侧（iSH / Codex）一条读系统数据的路。
///
/// 为什么需要：Codex 跑在 iSH 里，那是个独立的 Linux rootfs，看不到 /var/mobile。
/// 而本 App 是无沙盒进程，能读整台设备。于是在 127.0.0.1 开一个只服务回环的 HTTP 口，
/// Linux 里一条 curl 就能把系统文件取出来，不需要每次人工搬运。
enum NanoMuseHostBridge {
    static let port: UInt16 = 7788
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        Thread.detachNewThread { acceptLoop() }
    }

    private static func acceptLoop() {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(s, 16) == 0 else { close(s); return }
        while true {
            let c = accept(s, nil, nil)
            if c < 0 { continue }
            Thread.detachNewThread { handle(c) }
        }
    }

    private static func handle(_ fd: Int32) {
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return }
        var raw = Data(buf[0..<n])
        guard let headEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headText = String(decoding: raw[raw.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var body = raw[headEnd.upperBound...]
        let lines = headText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return }
        var contentLength = 0
        for l in lines.dropFirst() {
            let p = l.components(separatedBy: ": ")
            if p.count == 2, p[0].lowercased() == "content-length" { contentLength = Int(p[1]) ?? 0 }
        }
        while body.count < contentLength {
            let m = read(fd, &buf, buf.count)
            if m <= 0 { break }
            body.append(contentsOf: buf[0..<m])
        }
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        respond(fd, method: parts[0], target: parts[1], body: Data(body))
    }

    private static func respond(_ fd: Int32, method: String, target: String, body: Data) {
        let q = target.components(separatedBy: "?")
        let path = q[0]
        var params: [String: String] = [:]
        if q.count > 1 {
            for kv in q[1].components(separatedBy: "&") {
                let p = kv.components(separatedBy: "=")
                if p.count == 2 { params[p[0]] = p[1].removingPercentEncoding ?? p[1] }
            }
        }
        let fm = FileManager.default
        switch path {
        case "/ping":
            send(fd, 200, "text/plain", Data("PONG ios-host-bridge\n".utf8))
        case "/list":
            guard let p = params["p"] else { return send(fd, 400, "text/plain", Data("need p\n".utf8)) }
            guard let items = try? fm.contentsOfDirectory(atPath: p) else { return send(fd, 404, "text/plain", Data("no such dir\n".utf8)) }
            var out = "[\n"
            for (i, name) in items.sorted().enumerated() {
                let full = (p as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: full, isDirectory: &isDir)
                let attrs = (try? fm.attributesOfItem(atPath: full)) ?? [:]
                let size = (attrs[.size] as? Int) ?? 0
                out += "  {\"name\":\"\(name)\",\"dir\":\(exists && isDir.boolValue),\"size\":\(size)}\(i == items.count - 1 ? "" : ",")\n"
            }
            send(fd, 200, "application/json", Data((out + "]\n").utf8))
        case "/read":
            guard let p = params["p"] else { return send(fd, 400, "text/plain", Data("need p\n".utf8)) }
            guard let d = fm.contents(atPath: p) else { return send(fd, 404, "text/plain", Data("no such file\n".utf8)) }
            let limit = Int(params["max"] ?? "") ?? d.count
            send(fd, 200, "application/octet-stream", d.prefix(limit))
        case "/stat":
            guard let p = params["p"] else { return send(fd, 400, "text/plain", Data("need p\n".utf8)) }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return send(fd, 404, "text/plain", Data("absent\n".utf8)) }
            let a = (try? fm.attributesOfItem(atPath: p)) ?? [:]
            let size = (a[.size] as? Int) ?? 0
            let mode = (a[.posixPermissions] as? Int) ?? 0
            send(fd, 200, "application/json", Data("{\"path\":\"\(p)\",\"dir\":\(isDir.boolValue),\"size\":\(size),\"mode\":\(mode)}\n".utf8))
        case "/write":
            guard let p = params["p"] else { return send(fd, 400, "text/plain", Data("need p\n".utf8)) }
            do {
                try body.write(to: URL(fileURLWithPath: p))
                send(fd, 200, "text/plain", Data("ok \(body.count)\n".utf8))
            } catch {
                send(fd, 500, "text/plain", Data("write failed: \(error)\n".utf8))
            }
        case "/mkdir":
            guard let p = params["p"] else { return send(fd, 400, "text/plain", Data("need p\n".utf8)) }
            do { try fm.createDirectory(atPath: p, withIntermediateDirectories: true); send(fd, 200, "text/plain", Data("ok\n".utf8)) }
            catch { send(fd, 500, "text/plain", Data("mkdir failed: \(error)\n".utf8)) }
        case "/rm":
            guard let p = params["p"] else { return send(fd, 400, "text/plain", Data("need p\n".utf8)) }
            do { try fm.removeItem(atPath: p); send(fd, 200, "text/plain", Data("ok\n".utf8)) }
            catch { send(fd, 500, "text/plain", Data("rm failed: \(error)\n".utf8)) }
        case "/mv":
            guard let a = params["from"], let b = params["to"] else { return send(fd, 400, "text/plain", Data("need from,to\n".utf8)) }
            do { try fm.moveItem(atPath: a, toPath: b); send(fd, 200, "text/plain", Data("ok\n".utf8)) }
            catch { send(fd, 500, "text/plain", Data("mv failed: \(error)\n".utf8)) }
        case "/chmod":
            guard let p = params["p"], let m = params["mode"], let v = Int(m, radix: 8) else { return send(fd, 400, "text/plain", Data("need p,mode\n".utf8)) }
            do { try fm.setAttributes([.posixPermissions: v], ofItemAtPath: p); send(fd, 200, "text/plain", Data("ok\n".utf8)) }
            catch { send(fd, 500, "text/plain", Data("chmod failed: \(error)\n".utf8)) }
        default:
            send(fd, 404, "text/plain", Data("/ping /list /read /stat /write\n".utf8))
        }
    }

    private static func send(_ fd: Int32, _ code: Int, _ type: String, _ body: Data) {
        var head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "ERR")\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        out.withUnsafeBytes { ptr in
            var off = 0
            while off < out.count {
                let w = write(fd, ptr.baseAddress!.advanced(by: off), out.count - off)
                if w <= 0 { break }
                off += w
            }
        }
    }
}
