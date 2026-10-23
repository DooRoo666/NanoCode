import Foundation

/// Codex 的模型来源：两种，用户任选。
///   - `followNano`：直接复用 nanoMuse 里已经配好的 provider（base URL + 密钥）
///   - `custom`：自己填第三方地址与密钥，再在线拉模型
enum NanoMuseCodexSource: String, CaseIterable, Identifiable, Sendable {
    case followNano
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followNano: return "使用 nanoMuse 的模型服务"
        case .custom:     return "自己设置第三方"
        }
    }

    var subtitle: String {
        switch self {
        case .followNano: return "沿用「设置 › 模型」里已配好的地址与密钥，不用重填"
        case .custom:     return "填 Base URL + API Key，在线获取模型列表后挑选"
        }
    }
}

enum NanoMuseCodexModels {

    /// 从 nanoMuse 的 provider 里取来的一组凭据
    struct Inherited: Sendable {
        let label: String
        let baseURL: String
        let apiKey: String
    }

    // MARK: - 复用 nanoMuse 的 provider

    /// 取第一个「启用 + 有凭据 + 不是 Cloud」的 provider。
    /// `ProviderConfigStore` 是 @MainActor，所以这里必须回主线程读。
    @MainActor
    static func inherited() -> Inherited? {
        let store = ProviderConfigStore.shared
        let cloudID = NanoMuseCloud.instance?.id

        guard let inst = store.instances.first(where: { instance in
            instance.isEnabled && instance.hasAnyCredential && instance.id != cloudID
        }) else { return nil }

        let key = ProviderKeychainHelper.loadAPIKey(instanceId: inst.id) ?? ""
        let base = inst.effectiveCustomBaseURL ?? fallbackBase(for: inst)
        guard !base.isEmpty else { return nil }

        return Inherited(label: inst.label, baseURL: base, apiKey: key)
    }

    /// 少数内置 provider 没设自定义地址时，给一个已知默认值（只覆盖 OpenAI 兼容这一类）。
    private static func fallbackBase(for instance: ProviderInstance) -> String {
        if instance.providerType == .openAI { return "https://api.openai.com/v1" }
        return ""
    }

    // MARK: - 在线拉模型

    /// 依次尝试 `<base>/models`、`<base>/v1/models`，兼容两种常见写法。
    static func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NanoCodex", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先填 Base URL"])
        }
        let root = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed

        var candidates: [String] = []
        if root.hasSuffix("/v1") {
            candidates.append(root + "/models")
        } else {
            candidates.append(root + "/v1/models")
            candidates.append(root + "/models")
        }

        var lastError: Error?
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            do {
                return try await request(url: url, apiKey: apiKey)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "NanoCodex", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "地址无效"])
    }

    private static func request(url: URL, apiKey: String) async throws -> [String] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 25
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw NSError(domain: "NanoCodex", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "服务返回 HTTP \(status)"])
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let ids = identifiers(from: object)
        guard !ids.isEmpty else {
            throw NSError(domain: "NanoCodex", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "返回里没有模型列表"])
        }
        return Array(Set(ids)).sorted()
    }

    /// 兼容 `/v1/models` 的几种返回形状：`{data:[{id}]}`、`{models:[{id|name}]}`、`[ "id", … ]`
    private static func identifiers(from object: Any) -> [String] {
        if let dict = object as? [String: Any] {
            if let rows = dict["data"] as? [[String: Any]] {
                return rows.compactMap { $0["id"] as? String }
            }
            if let rows = dict["models"] as? [[String: Any]] {
                return rows.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            }
            if let names = dict["models"] as? [String] {
                return names
            }
            if let ids = dict["ids"] as? [String] {
                return ids
            }
        }
        if let names = object as? [String] {
            return names
        }
        return []
    }
}
