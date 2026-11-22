import Foundation

public enum SubscriptionDownload {
    static let userAgent = "Clash.Meta Xeylroute"

    public static func fetch(_ url: URL) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProfileStoreError.ioError("订阅服务器未返回 HTTP 响应。")
        }
        return try validatedPayload(data, status: http.statusCode)
    }

    static func validatedPayload(_ data: Data, status: Int) throws -> String {
        switch status {
        case 200..<300: break
        case 401, 403: throw ProfileStoreError.ioError("订阅服务拒绝访问（HTTP \(status)）。请检查链接或订阅有效期。")
        case 404, 410: throw ProfileStoreError.ioError("订阅地址已不存在（HTTP \(status)）。")
        default: throw ProfileStoreError.ioError("订阅服务器返回 HTTP \(status)。")
        }
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw ProfileStoreError.invalidProfile("订阅响应不是 UTF-8 文本。")
        }
        let text = decoded.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        if text.hasPrefix("<") {
            throw ProfileStoreError.invalidProfile("服务器返回了网页，请使用客户端订阅链接。")
        }
        if ShareLinkParser.looksLikeShareLinks(text) {
            let nodes = try ShareLinkParser.parseBundle(text)
            return SimpleYAML.emit(.object(["proxies": .array(nodes)]))
        }
        guard let proxies = try SimpleYAML.parse(text)["proxies"]?.arrayValue,
              proxies.contains(where: { $0["name"]?.stringValue?.isEmpty == false && $0["type"]?.stringValue?.isEmpty == false })
        else {
            throw ProfileStoreError.invalidProfile("订阅中没有可用节点，请检查链接是否返回 Clash 配置或节点分享链接。")
        }
        return text
    }
}
