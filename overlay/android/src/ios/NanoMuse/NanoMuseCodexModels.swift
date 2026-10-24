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
        /// 该 provider 的 /models 里第一个模型（codex 的默认模型第三方网关多半没有）
        var model: String = ""
        var instanceID: String = ""
    }

    /// 单个 provider 的实测结果（密钥内容不落地，只记长度）
    struct Probe: Sendable {
        let label: String
        let instanceID: String
        let baseURL: String
        let hasKey: Bool
        let keyLength: Int
        /// 0 = 没探（没 key / 地址空），-1 = 网络异常
        let httpStatus: Int
        let models: [String]

        var line: String {
            var parts = ["「\(label)」", baseURL]
            parts.append(hasKey ? "key \(keyLength) 字符" : "无 key")
            if httpStatus == 200 { parts.append("HTTP 200 · \(models.count) 个模型") }
            else if httpStatus == 0 { parts.append("未探测") }
            else if httpStatus == -1 { parts.append("网络异常") }
            else { parts.append("HTTP \(httpStatus)") }
            return parts.joined(separator: " · ")
        }
    }

    /// 逐个启用中的 provider 实测 `/models`，选第一个「有 key 且 200」的。
    /// 这样不用猜"列表第一个是不是用户那家"，也不用把 key 暴露给任何外部进程。
    @MainActor
    static func resolveBest() async -> (chosen: Inherited?, probes: [Probe]) {
        let store = ProviderConfigStore.shared
        let cloudID = NanoMuseCloud.instance?.id
        let candidates = store.instances.filter { candidate in
            candidate.isEnabled && candidate.id != cloudID
        }

        var probes: [Probe] = []
        var fallback: Inherited?
        for instance in candidates {
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            let base = instance.effectiveCustomBaseURL ?? fallbackBase(for: instance)
            guard !base.isEmpty else { continue }

            if key.isEmpty {
                probes.append(Probe(label: instance.label, instanceID: instance.id, baseURL: base,
                                    hasKey: false, keyLength: 0, httpStatus: 0, models: []))
                continue
            }

            let (status, models) = await probeModels(baseURL: base, apiKey: key)
            probes.append(Probe(label: instance.label, instanceID: instance.id, baseURL: base,
                                hasKey: true, keyLength: key.count, httpStatus: status, models: models))

            let candidate = Inherited(label: instance.label, baseURL: base, apiKey: key,
                                      model: models.first ?? "", instanceID: instance.id)
            if status == 200 {
                return (candidate, probes)
            }
            if fallback == nil { fallback = candidate }
        }
        return (fallback, probes)
    }

    /// 打一次 `<base>/models`，拿到 HTTP 码与模型列表
    static func probeModels(baseURL: String, apiKey: String) async -> (Int, [String]) {
        let root = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let candidate = root.hasSuffix("/v1") ? root + "/models" : root + "/v1/models"
        guard let url = URL(string: candidate) else { return (0, []) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
            return (status, identifiers(from: object))
        } catch {
            return (-1, [])
        }
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

    // MARK: - 复用 nanoMuse 的模型目录（follow 模式）

    /// 站在上游肩膀上：`ProviderConfigStore.fetchModelsForInstance` 已经处理了
    /// `appendV1Suffix`、自定义 UA、OAuth 路径等细节，比自己拼 `/v1/models` 靠谱。
    @MainActor
    static func fetchInheritedModels() async throws -> [String] {
        let store = ProviderConfigStore.shared
        let cloudID = NanoMuseCloud.instance?.id
        guard let instance = store.instances.first(where: { candidate in
            candidate.isEnabled && candidate.hasAnyCredential && candidate.id != cloudID
        }) else {
            throw NSError(domain: "NanoCodex", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "「设置 › 模型」里还没有可用的 provider"])
        }
        let models = try await ProviderConfigStore.fetchModelsForInstance(instance, forceRefresh: true)
        return models.map(\.id).sorted()
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
