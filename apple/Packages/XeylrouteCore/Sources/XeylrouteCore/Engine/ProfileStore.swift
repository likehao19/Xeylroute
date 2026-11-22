import Foundation

public enum ProfileStoreError: LocalizedError, Sendable {
    case invalidProfile(String)
    case duplicateBinding(UInt16)
    case missingResource(String)
    case referenceConflict(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let msg),
             .missingResource(let msg),
             .referenceConflict(let msg),
             .ioError(let msg):
            return msg
        case .duplicateBinding(let port):
            return "端口 \(port) 已有固定 SOCKS5 入口。"
        }
    }
}

/// Manages Xeylroute's persistent Mihomo configuration, subscriptions, routing rules,
/// policy groups, fixed SOCKS5 listeners, backups, and runtime config synthesis.
public actor ProfileStore {
    public static let fixedSocksKey = "routepilot-fixed-socks"
    public static let disabledRulesKey = "routepilot-disabled-rules"
    public static let disabledGroupsKey = "routepilot-disabled-groups"
    public static let tunScopeKey = "routepilot-tun-scope"
    public static let subscriptionScopeKey = "routepilot-subscription-scope"
    public static let manualOrderKey = "routepilot-manual-order"
    public static let fallbackDirectKey = "routepilot-fallback-direct"
    public static let probeGroupName = "RoutePilot.Internal.SpeedTest"

    public let dataDirectory: URL
    public let configURL: URL
    public let backupURL: URL
    public let providersDirectory: URL

    private var rootConfig: JSONValue

    public init(dataDirectory: URL) throws {
        self.dataDirectory = dataDirectory
        self.configURL = dataDirectory.appendingPathComponent("mihomo.json")
        self.backupURL = dataDirectory.appendingPathComponent("mihomo.backup.json")
        self.providersDirectory = dataDirectory.appendingPathComponent("providers", isDirectory: true)

        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providersDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: configURL.path),
           let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONValue.decode(from: data),
           decoded.objectValue != nil
        {
            self.rootConfig = decoded
        } else {
            self.rootConfig = Self.defaultConfig()
            try Self.writeJSON(self.rootConfig, to: configURL)
        }
    }

    public static func defaultConfig() -> JSONValue {
        .object([
            "mixed-port": .int(7890),
            "port": .int(0),
            "socks-port": .int(0),
            "allow-lan": .bool(false),
            "bind-address": .string("127.0.0.1"),
            "mode": .string("rule"),
            "ipv6": .bool(false),
            "tcp-concurrent": .bool(true),
            "unified-delay": .bool(true),
            "log-level": .string("info"),
            "proxies": .array([]),
            "proxy-groups": .array([]),
            "proxy-providers": .object([:]),
            "rules": .array([.string("MATCH,AUTO")]),
            tunScopeKey: .string("all"),
            fallbackDirectKey: .bool(true),
        ])
    }

    // MARK: - Summary & Inspection

    public func summary() -> ProfileSummary {
        let mode = RoutingMode(rawValue: rootConfig["mode"]?.stringValue ?? "rule") ?? .rule
        let mixedPort = UInt16(clamping: rootConfig["mixed-port"]?.intValue ?? 7890)
        let httpPort = UInt16(clamping: rootConfig["port"]?.intValue ?? 0)
        let socksPort = UInt16(clamping: rootConfig["socks-port"]?.intValue ?? 0)
        let coreSettings = CoreSettings(
            ipv6: rootConfig["ipv6"]?.boolValue ?? false,
            tcpConcurrent: rootConfig["tcp-concurrent"]?.boolValue ?? true,
            unifiedDelay: rootConfig["unified-delay"]?.boolValue ?? true,
            logLevel: rootConfig["log-level"]?.stringValue ?? "info"
        )
        let tunScope = TunScope(rawValue: rootConfig[Self.tunScopeKey]?.stringValue ?? "all") ?? .all
        let subScope = rootConfig[Self.subscriptionScopeKey]?.stringValue
        let manualOrder = rootConfig[Self.manualOrderKey]?.boolValue ?? false
        let fallbackToDirect = rootConfig[Self.fallbackDirectKey]?.boolValue ?? true

        let disabledRules = Set(rootConfig[Self.disabledRulesKey]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let disabledGroups = Set(rootConfig[Self.disabledGroupsKey]?.arrayValue?.compactMap(\.stringValue) ?? [])

        let rawRules = rootConfig["rules"]?.arrayValue?.compactMap(\.stringValue) ?? ["MATCH,AUTO"]
        let rules: [ProfileRule] = rawRules.enumerated().compactMap { idx, line in
            guard let parsed = RuleConditionsEngine.parseRuleLine(line) else { return nil }
            return ProfileRule(
                index: idx,
                rawLine: line,
                kind: parsed.kind,
                payload: parsed.payload,
                exit: parsed.exit,
                enabled: !disabledRules.contains(line),
                conditions: RuleConditionsEngine.decode(kind: parsed.kind, payload: parsed.payload)
            )
        }

        let groups: [PolicyGroup] = (rootConfig["proxy-groups"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue, !name.isEmpty else { return nil }
            let type = entry["type"]?.stringValue ?? "select"
            let proxies = entry["proxies"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let use = entry["use"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return PolicyGroup(
                name: name,
                type: type,
                proxies: proxies,
                use: use,
                enabled: !disabledGroups.contains(name)
            )
        }

        let providers: [SubscriptionProvider] = (rootConfig["proxy-providers"]?.objectValue ?? [:])
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { name, entry in
                let type = entry["type"]?.stringValue ?? "file"
                let interval = entry["interval"]?.intValue ?? 3600
                let url = entry["url"]?.stringValue
                let path = entry["path"]?.stringValue
                let cachedNodes = readProviderNodes(path: path, providerName: name)
                let fileDate = path.flatMap { fileModificationDate(for: $0) }
                return SubscriptionProvider(
                    name: name,
                    type: type,
                    interval: interval,
                    url: url,
                    path: path,
                    updatedAt: fileDate,
                    nodes: cachedNodes
                )
            }

        let standaloneNodes: [ProxyNode] = (rootConfig["proxies"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue, !name.isEmpty else { return nil }
            return ProxyNode(
                name: name,
                type: entry["type"]?.stringValue ?? "proxy",
                provider: nil,
                isPolicy: false
            )
        }

        let fixedSocks = decodeFixedSocks()
        let effectiveRules = buildEffectiveRules(
            rawRules: rawRules,
            disabledRules: disabledRules,
            disabledGroups: disabledGroups,
            manualOrder: manualOrder
        )

        var exits = ["AUTO", "DIRECT", "REJECT"]
        for group in groups where !exits.contains(group.name) {
            exits.append(group.name)
        }
        for node in standaloneNodes where !exits.contains(node.name) {
            exits.append(node.name)
        }
        if let activeScope = subScope ?? providers.first?.name,
           let activeProvider = providers.first(where: { $0.name == activeScope })
        {
            for node in activeProvider.nodes where !exits.contains(node.name) {
                exits.append(node.name)
            }
        }

        return ProfileSummary(
            mode: mode,
            mixedPort: mixedPort,
            httpPort: httpPort,
            socksPort: socksPort,
            coreSettings: coreSettings,
            tunScope: tunScope,
            subscriptionScope: subScope,
            rules: rules,
            effectiveRules: effectiveRules,
            manualOrder: manualOrder,
            groups: groups,
            providers: providers,
            standaloneNodes: standaloneNodes,
            exits: exits,
            fixedSocks: fixedSocks,
            fallbackToDirect: fallbackToDirect
        )
    }

    // MARK: - Core Settings & Ports

    public func setMode(_ mode: RoutingMode) throws -> ProfileSummary {
        rootConfig["mode"] = .string(mode.rawValue)
        try persist()
        return summary()
    }

    public func setPorts(mixed: UInt16, http: UInt16, socks: UInt16) throws -> ProfileSummary {
        let nonZero = [mixed, http, socks].filter { $0 > 0 }
        guard !nonZero.isEmpty else {
            throw ProfileStoreError.invalidProfile("请至少启用一个本地监听端口。")
        }
        if Set(nonZero).count != nonZero.count {
            throw ProfileStoreError.invalidProfile("MIX、HTTP 与 SOCKS 端口不能重复。")
        }
        let fixedPorts = Set(decodeFixedSocks().map(\.port))
        if let conflict = nonZero.first(where: { fixedPorts.contains($0) }) {
            throw ProfileStoreError.invalidProfile("端口 \(conflict) 已被固定 SOCKS5 入口占用。")
        }
        rootConfig["mixed-port"] = .int(Int64(mixed))
        rootConfig["port"] = .int(Int64(http))
        rootConfig["socks-port"] = .int(Int64(socks))
        try persist()
        return summary()
    }

    public func updateCoreSettings(_ settings: CoreSettings) throws -> ProfileSummary {
        rootConfig["ipv6"] = .bool(settings.ipv6)
        rootConfig["tcp-concurrent"] = .bool(settings.tcpConcurrent)
        rootConfig["unified-delay"] = .bool(settings.unifiedDelay)
        rootConfig["log-level"] = .string(settings.logLevel)
        try persist()
        return summary()
    }

    public func setTunScope(_ scope: TunScope) throws -> ProfileSummary {
        rootConfig[Self.tunScopeKey] = .string(scope.rawValue)
        try persist()
        return summary()
    }

    public func setFallbackToDirect(_ enabled: Bool) throws -> ProfileSummary {
        rootConfig[Self.fallbackDirectKey] = .bool(enabled)
        try persist()
        return summary()
    }

    public func setSubscriptionScope(_ name: String?) throws -> ProfileSummary {
        if let name, !name.isEmpty {
            guard rootConfig["proxy-providers"]?[name] != nil else {
                throw ProfileStoreError.missingResource("订阅「\(name)」不存在。")
            }
            rootConfig[Self.subscriptionScopeKey] = .string(name)
        } else {
            rootConfig[Self.subscriptionScopeKey] = nil
        }
        try persist()
        return summary()
    }

    // MARK: - Rules

    public func addOrUpdateRule(
        editingLine: String?,
        conditions: RuleConditions,
        exit: String
    ) throws -> ProfileSummary {
        let compiled = try RuleConditionsEngine.compile(conditions)
        let newLine = RuleConditionsEngine.formatRuleLine(
            kind: compiled.kind,
            payload: compiled.payload,
            exit: exit
        )
        var rules = rootConfig["rules"]?.arrayValue?.compactMap(\.stringValue) ?? ["MATCH,AUTO"]
        if let editingLine, let idx = rules.firstIndex(of: editingLine) {
            rules[idx] = newLine
            var disabled = rootConfig[Self.disabledRulesKey]?.arrayValue?.compactMap(\.stringValue) ?? []
            if let dIdx = disabled.firstIndex(of: editingLine) {
                disabled[dIdx] = newLine
                rootConfig[Self.disabledRulesKey] = .array(disabled.map(JSONValue.string))
            }
        } else {
            let matchIdx = rules.lastIndex(where: { $0.uppercased().hasPrefix("MATCH,") }) ?? rules.count
            rules.insert(newLine, at: matchIdx)
        }
        rootConfig["rules"] = .array(rules.map(JSONValue.string))
        try persist()
        return summary()
    }

    public func setDefaultExit(_ exit: String) throws -> ProfileSummary {
        var rules = rootConfig["rules"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let line = "MATCH,\(exit)"
        if let idx = rules.lastIndex(where: { $0.uppercased().hasPrefix("MATCH,") }) {
            rules[idx] = line
        } else {
            rules.append(line)
        }
        rootConfig["rules"] = .array(rules.map(JSONValue.string))
        try persist()
        return summary()
    }

    public func toggleRule(rawLine: String, enabled: Bool) throws -> ProfileSummary {
        var disabled = Set(rootConfig[Self.disabledRulesKey]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if enabled {
            disabled.remove(rawLine)
        } else {
            disabled.insert(rawLine)
        }
        rootConfig[Self.disabledRulesKey] = .array(disabled.sorted().map(JSONValue.string))
        try persist()
        return summary()
    }

    public func deleteRules(_ lines: Set<String>) throws -> ProfileSummary {
        let current = rootConfig["rules"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let remaining = current.filter { $0.uppercased().hasPrefix("MATCH,") || !lines.contains($0) }
        var disabled = Set(rootConfig[Self.disabledRulesKey]?.arrayValue?.compactMap(\.stringValue) ?? [])
        disabled.subtract(lines)
        rootConfig["rules"] = .array(remaining.map(JSONValue.string))
        rootConfig[Self.disabledRulesKey] = .array(disabled.sorted().map(JSONValue.string))
        try persist()
        return summary()
    }

    public func setManualRuleOrder(_ orderedLines: [String]?, manual: Bool) throws -> ProfileSummary {
        rootConfig[Self.manualOrderKey] = .bool(manual)
        if let orderedLines {
            rootConfig["rules"] = .array(orderedLines.map(JSONValue.string))
        }
        try persist()
        return summary()
    }

    public func setProgramExits(paths: [String], exit: String?) throws -> ProfileSummary {
        let normalizedTargets = Set(paths.map { RunningAppGrouper.normalizePath($0) })
        var rules = rootConfig["rules"]?.arrayValue?.compactMap(\.stringValue) ?? ["MATCH,AUTO"]
        rules.removeAll { line in
            guard let parsed = RuleConditionsEngine.parseRuleLine(line),
                  parsed.kind == "PROCESS-PATH"
            else { return false }
            return normalizedTargets.contains(RunningAppGrouper.normalizePath(parsed.payload))
        }
        if let exit, !exit.isEmpty {
            let insertAt = rules.lastIndex(where: { $0.uppercased().hasPrefix("MATCH,") }) ?? rules.count
            for (offset, path) in paths.enumerated() {
                rules.insert("PROCESS-PATH,\(path),\(exit)", at: insertAt + offset)
            }
        }
        rootConfig["rules"] = .array(rules.map(JSONValue.string))
        try persist()
        return summary()
    }

    // MARK: - Policy Groups

    public func upsertGroup(_ group: PolicyGroup, originalName: String? = nil) throws -> ProfileSummary {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !["GLOBAL", "DIRECT", "REJECT", "PASS", Self.probeGroupName].contains(name) else {
            throw ProfileStoreError.invalidProfile("策略组名称无效或为系统保留名称。")
        }
        var groups = rootConfig["proxy-groups"]?.arrayValue ?? []
        var obj: [String: JSONValue] = [
            "name": .string(name),
            "type": .string(group.type),
        ]
        if !group.proxies.isEmpty {
            obj["proxies"] = .array(group.proxies.map(JSONValue.string))
        }
        if !group.use.isEmpty {
            obj["use"] = .array(group.use.map(JSONValue.string))
        }
        if group.type == "url-test" || group.type == "fallback" {
            obj["url"] = .string("https://www.gstatic.com/generate_204")
            obj["interval"] = .int(300)
        }
        let targetName = originalName ?? name
        if let idx = groups.firstIndex(where: { $0["name"]?.stringValue == targetName }) {
            groups[idx] = .object(obj)
        } else {
            groups.append(.object(obj))
        }
        rootConfig["proxy-groups"] = .array(groups)
        try persist()
        return summary()
    }

    public func toggleGroup(name: String, enabled: Bool) throws -> ProfileSummary {
        var disabled = Set(rootConfig[Self.disabledGroupsKey]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if enabled {
            disabled.remove(name)
        } else {
            disabled.insert(name)
        }
        rootConfig[Self.disabledGroupsKey] = .array(disabled.sorted().map(JSONValue.string))
        try persist()
        return summary()
    }

    public func removeGroup(name: String) throws -> ProfileSummary {
        var groups = rootConfig["proxy-groups"]?.arrayValue ?? []
        groups.removeAll { $0["name"]?.stringValue == name }
        rootConfig["proxy-groups"] = .array(groups)
        var disabled = Set(rootConfig[Self.disabledGroupsKey]?.arrayValue?.compactMap(\.stringValue) ?? [])
        disabled.remove(name)
        rootConfig[Self.disabledGroupsKey] = .array(disabled.sorted().map(JSONValue.string))
        try persist()
        return summary()
    }

    // MARK: - Subscriptions, Share Links & YAML Import

    public func addRemoteSubscription(name: String?, urlString: String, interval: Int = 3600) throws -> ProfileSummary {
        _ = try createRemoteSubscription(name: name, urlString: urlString, interval: interval)
        return summary()
    }

    public func createRemoteSubscription(name: String?, urlString: String, interval: Int = 3600) throws -> String {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host, !host.isEmpty
        else {
            throw ProfileStoreError.invalidProfile("请输入有效的 HTTP 或 HTTPS 订阅链接。")
        }
        var providers = rootConfig["proxy-providers"]?.objectValue ?? [:]
        let baseName = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? host
        let uniqueName = makeUniqueName(baseName, existing: Set(providers.keys))
        let fileName = sanitizeFileName(uniqueName) + ".yaml"
        let relPath = "providers/\(fileName)"
        providers[uniqueName] = .object([
            "type": .string("http"),
            "url": .string(url.absoluteString),
            "path": .string(relPath),
            "interval": .int(Int64(max(0, interval))),
            "health-check": .object([
                "enable": .bool(true),
                "url": .string("https://www.gstatic.com/generate_204"),
                "interval": .int(300),
            ]),
        ])
        rootConfig["proxy-providers"] = .object(providers)
        if rootConfig[Self.subscriptionScopeKey]?.stringValue == nil {
            rootConfig[Self.subscriptionScopeKey] = .string(uniqueName)
        }
        try persist()
        return uniqueName
    }

    public func updateSubscriptionURL(name: String, newURL: String, interval: Int? = nil) throws -> ProfileSummary {
        guard var providers = rootConfig["proxy-providers"]?.objectValue,
              var entry = providers[name]?.objectValue
        else {
            throw ProfileStoreError.missingResource("订阅「\(name)」不存在。")
        }
        entry["url"] = .string(newURL.trimmingCharacters(in: .whitespacesAndNewlines))
        if let interval {
            entry["interval"] = .int(Int64(max(0, interval)))
        }
        providers[name] = .object(entry)
        rootConfig["proxy-providers"] = .object(providers)
        try persist()
        return summary()
    }

    public func importShareLinks(_ content: String) throws -> (summary: ProfileSummary, addedCount: Int) {
        let parsed = try ShareLinkParser.parseBundle(content)
        var existing = rootConfig["proxies"]?.arrayValue ?? []
        var usedNames = Set(existing.compactMap { $0["name"]?.stringValue })
        for var node in parsed {
            let rawName = node["name"]?.stringValue ?? "节点"
            let unique = makeUniqueName(rawName, existing: usedNames)
            usedNames.insert(unique)
            node["name"] = .string(unique)
            existing.append(node)
        }
        rootConfig["proxies"] = .array(existing)
        try persist()
        return (summary(), parsed.count)
    }

    public func importLocalSubscriptionYAML(name: String, content: String) throws -> ProfileSummary {
        let parsed = try SimpleYAML.parse(content)
        guard let proxies = parsed["proxies"]?.arrayValue, !proxies.isEmpty else {
            if ShareLinkParser.looksLikeShareLinks(content) {
                let nodes = try ShareLinkParser.parseBundle(content)
                let yamlText = SimpleYAML.emit(.object(["proxies": .array(nodes)]))
                return try saveLocalProviderFile(name: name, yamlContent: yamlText)
            }
            throw ProfileStoreError.invalidProfile("文件内容未包含有效的 proxies 节点列表。")
        }
        return try saveLocalProviderFile(name: name, yamlContent: content)
    }

    public func importFullConfig(content: String) throws -> ProfileSummary {
        let parsed = try SimpleYAML.parse(content)
        guard parsed.objectValue != nil else {
            throw ProfileStoreError.invalidProfile("配置文件必须是有效的 YAML 或 JSON 对象。")
        }
        rootConfig = parsed
        try persist()
        return summary()
    }

    public func readDocument(providerName: String?) throws -> String {
        if let providerName {
            guard let path = rootConfig["proxy-providers"]?[providerName]?["path"]?.stringValue else {
                throw ProfileStoreError.missingResource("找不到订阅文件：\(providerName)")
            }
            let fileURL = resolveProviderURL(path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return try String(contentsOf: fileURL, encoding: .utf8)
            }
            return "# 订阅文件尚未拉取，启动内核或刷新订阅后会写入此处。\nproxies: []\n"
        }
        return SimpleYAML.emit(rootConfig)
    }

    public func saveProviderPayload(name: String, yamlContent: String) throws {
        guard let path = rootConfig["proxy-providers"]?[name]?["path"]?.stringValue else {
            throw ProfileStoreError.missingResource("订阅「\(name)」不存在。")
        }
        let fileURL = resolveProviderURL(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yamlContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    public func removeProvider(name: String) throws -> ProfileSummary {
        let fixed = decodeFixedSocks()
        if let binding = fixed.first(where: { $0.provider == name }) {
            throw ProfileStoreError.referenceConflict("端口 \(binding.port) 的固定 SOCKS5 入口仍绑定订阅「\(name)」，请先移除该入口。")
        }
        var providers = rootConfig["proxy-providers"]?.objectValue ?? [:]
        if let path = providers[name]?["path"]?.stringValue {
            try? FileManager.default.removeItem(at: resolveProviderURL(path))
        }
        providers.removeValue(forKey: name)
        rootConfig["proxy-providers"] = .object(providers)
        if rootConfig[Self.subscriptionScopeKey]?.stringValue == name {
            rootConfig[Self.subscriptionScopeKey] = providers.keys.sorted().first.map(JSONValue.string)
        }
        try persist()
        return summary()
    }

    public func removeStandaloneNode(name: String) throws -> ProfileSummary {
        let fixed = decodeFixedSocks()
        if let binding = fixed.first(where: { $0.provider == nil && $0.node == name }) {
            throw ProfileStoreError.referenceConflict("端口 \(binding.port) 的固定 SOCKS5 入口仍绑定节点「\(name)」，请先移除该入口。")
        }
        var proxies = rootConfig["proxies"]?.arrayValue ?? []
        proxies.removeAll { $0["name"]?.stringValue == name }
        rootConfig["proxies"] = .array(proxies)
        try persist()
        return summary()
    }

    // MARK: - Fixed Loopback SOCKS5 Listeners

    public func addFixedSocks(_ binding: FixedSocksBinding) throws -> ProfileSummary {
        guard binding.port > 0 else {
            throw ProfileStoreError.invalidProfile("请输入 1–65535 之间的有效端口号。")
        }
        let current = summary()
        if [current.mixedPort, current.httpPort, current.socksPort].contains(binding.port) {
            throw ProfileStoreError.invalidProfile("端口 \(binding.port) 已被主代理监听占用。")
        }
        var list = decodeFixedSocks()
        if list.contains(where: { $0.port == binding.port }) {
            throw ProfileStoreError.duplicateBinding(binding.port)
        }
        list.append(binding)
        encodeFixedSocks(list)
        try persist()
        return summary()
    }

    public func removeFixedSocks(_ binding: FixedSocksBinding) throws -> ProfileSummary {
        var list = decodeFixedSocks()
        list.removeAll { $0 == binding }
        encodeFixedSocks(list)
        try persist()
        return summary()
    }

    public static func clashSnippet(for binding: FixedSocksBinding) -> String {
        let proxyName = "Xeylroute-\(binding.node)-\(binding.port)"
        return """
        # 1. 将以下节点并入 Clash 配置的 proxies 列表：
        proxies:
          - name: "\(proxyName)"
            type: socks5
            server: 127.0.0.1
            port: \(binding.port)
            udp: true

        # 2. 在 Clash 配置的 rules 顶部添加需要固定出口的应用或域名规则：
        rules:
          - PROCESS-NAME,ChatGPT,\(proxyName)
          - DOMAIN-SUFFIX,openai.com,\(proxyName)
        """
    }

    // MARK: - Backup & Restore

    public func saveBackup() throws {
        try Self.writeJSON(rootConfig, to: backupURL)
    }

    public func restoreBackup() throws -> ProfileSummary {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw ProfileStoreError.missingResource("尚未找到已保存的备份文件。")
        }
        let data = try Data(contentsOf: backupURL)
        let decoded = try JSONValue.decode(from: data)
        guard decoded.objectValue != nil else {
            throw ProfileStoreError.invalidProfile("备份文件格式无效。")
        }
        rootConfig = decoded
        try persist()
        return summary()
    }

    // MARK: - Runtime Config Synthesis (Passed to Mihomo)

    public func buildRuntimeConfig(
        controllerPort: UInt16,
        secret: String,
        probePort: UInt16,
        enableTUN: Bool
    ) throws -> Data {
        var runtime = rootConfig
        let current = summary()

        if enableTUN && current.tunScope == .selected {
            throw ProfileStoreError.invalidProfile("当前内核不支持仅按指定程序限定 TUN 入站，请将 TUN 范围切换为「全部受支持流量」。")
        }

        // Strip Xeylroute metadata keys before handing JSON to Mihomo
        for metaKey in [
            Self.fixedSocksKey,
            Self.disabledRulesKey,
            Self.disabledGroupsKey,
            Self.tunScopeKey,
            Self.subscriptionScopeKey,
            Self.manualOrderKey,
            Self.fallbackDirectKey,
        ] {
            runtime[metaKey] = nil
        }

        runtime["external-controller"] = .string("127.0.0.1:\(controllerPort)")
        runtime["secret"] = .string(secret)
        runtime["allow-lan"] = .bool(false)
        runtime["bind-address"] = .string("127.0.0.1")

        // Ensure AUTO group exists when nodes/providers are available
        var groups = runtime["proxy-groups"]?.arrayValue ?? []
        let disabledGroups = Set(rootConfig[Self.disabledGroupsKey]?.arrayValue?.compactMap(\.stringValue) ?? [])
        groups.removeAll { disabledGroups.contains($0["name"]?.stringValue ?? "") }

        let allProviderNames = Array((runtime["proxy-providers"]?.objectValue ?? [:]).keys).sorted()
        let standaloneNames = (runtime["proxies"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }

        if !groups.contains(where: { $0["name"]?.stringValue == "AUTO" }) {
            var autoGroup: [String: JSONValue] = [
                "name": .string("AUTO"),
                "type": .string("url-test"),
                "url": .string("https://www.gstatic.com/generate_204"),
                "interval": .int(300),
                "tolerance": .int(50),
            ]
            if !allProviderNames.isEmpty {
                autoGroup["use"] = .array(allProviderNames.map(JSONValue.string))
            }
            if !standaloneNames.isEmpty {
                autoGroup["proxies"] = .array(standaloneNames.map(JSONValue.string))
            } else if allProviderNames.isEmpty {
                autoGroup["proxies"] = .array([.string("DIRECT")])
            }
            groups.insert(.object(autoGroup), at: 0)
        }

        // Listeners: internal speed test + fixed loopback SOCKS5 bindings
        var listeners = runtime["listeners"]?.arrayValue ?? []

        // Internal speedtest select group + HTTP listener
        var probeMembers = ["DIRECT"] + standaloneNames
        for g in groups {
            if let name = g["name"]?.stringValue, name != "GLOBAL" && name != Self.probeGroupName {
                probeMembers.append(name)
            }
        }
        groups.append(.object([
            "name": .string(Self.probeGroupName),
            "type": .string("select"),
            "hidden": .bool(true),
            "proxies": .array(probeMembers.map(JSONValue.string)),
            "use": .array(allProviderNames.map(JSONValue.string)),
        ]))
        listeners.append(.object([
            "name": .string("RoutePilot-SpeedTest"),
            "type": .string("http"),
            "listen": .string("127.0.0.1"),
            "port": .int(Int64(probePort)),
            "proxy": .string(Self.probeGroupName),
            "users": .array([.object([
                "username": .string("routepilot"),
                "password": .string(secret),
            ])]),
        ]))

        // Fixed SOCKS5 listeners pinned to exact nodes
        for binding in current.fixedSocks {
            let listenerName = "Xeylroute.SOCKS.\(binding.port)"
            let targetProxy: String
            if let provider = binding.provider {
                let escaped = NSRegularExpression.escapedPattern(for: binding.node)
                groups.append(.object([
                    "name": .string(listenerName),
                    "type": .string("select"),
                    "hidden": .bool(true),
                    "use": .array([.string(provider)]),
                    "filter": .string("^\(escaped)$"),
                    "empty-fallback": .string("REJECT"),
                ]))
                targetProxy = listenerName
            } else {
                targetProxy = binding.node
            }
            listeners.append(.object([
                "name": .string(listenerName),
                "type": .string("socks"),
                "listen": .string("127.0.0.1"),
                "port": .int(Int64(binding.port)),
                "udp": .bool(true),
                "users": .array([]),
                "proxy": .string(targetProxy),
            ]))
        }

        runtime["proxy-groups"] = .array(groups)
        runtime["listeners"] = .array(listeners)
        runtime["rules"] = .array(current.effectiveRules.map(JSONValue.string))

        if enableTUN {
            runtime["dns"] = .object([
                "enable": .bool(true),
                "enhanced-mode": .string("fake-ip"),
                "fake-ip-range": .string("198.18.0.1/16"),
                "nameserver": .array([.string("223.5.5.5"), .string("1.1.1.1")]),
            ])
            runtime["tun"] = .object([
                "enable": .bool(true),
                "stack": .string("mixed"),
                "auto-route": .bool(true),
                "auto-detect-interface": .bool(true),
                "dns-hijack": .array([.string("any:53")]),
            ])
        } else {
            runtime["tun"] = .object(["enable": .bool(false)])
        }

        return try runtime.prettyJSONData()
    }

    // MARK: - Private Helpers

    private func saveLocalProviderFile(name: String, yamlContent: String) throws -> ProfileSummary {
        var providers = rootConfig["proxy-providers"]?.objectValue ?? [:]
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".yaml", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".yml", with: "", options: .caseInsensitive)
            .nilIfEmpty ?? "本地订阅"
        let fileName = sanitizeFileName(cleanName) + ".yaml"
        let relPath = "providers/\(fileName)"
        let fileURL = resolveProviderURL(relPath)
        try yamlContent.write(to: fileURL, atomically: true, encoding: .utf8)

        providers[cleanName] = .object([
            "type": .string("file"),
            "path": .string(relPath),
            "health-check": .object([
                "enable": .bool(true),
                "url": .string("https://www.gstatic.com/generate_204"),
                "interval": .int(300),
            ]),
        ])
        rootConfig["proxy-providers"] = .object(providers)
        if rootConfig[Self.subscriptionScopeKey]?.stringValue == nil {
            rootConfig[Self.subscriptionScopeKey] = .string(cleanName)
        }
        try persist()
        return summary()
    }

    private func buildEffectiveRules(
        rawRules: [String],
        disabledRules: Set<String>,
        disabledGroups: Set<String>,
        manualOrder: Bool
    ) -> [String] {
        let active = rawRules.filter { line in
            if disabledRules.contains(line) { return false }
            if let parsed = RuleConditionsEngine.parseRuleLine(line), disabledGroups.contains(parsed.exit) {
                return false
            }
            return true
        }
        let hasMatch = active.contains { $0.uppercased().hasPrefix("MATCH,") }
        let lanRules = [
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR6,::1/128,DIRECT,no-resolve",
            "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
        ]
        var result: [String] = []
        if manualOrder {
            result = active
        } else {
            let nonMatch = active.filter { !$0.uppercased().hasPrefix("MATCH,") }
            let matches = active.filter { $0.uppercased().hasPrefix("MATCH,") }
            result = lanRules + nonMatch + matches
        }
        if !hasMatch {
            result.append("MATCH,AUTO")
        }
        return result
    }

    private func decodeFixedSocks() -> [FixedSocksBinding] {
        guard let arr = rootConfig[Self.fixedSocksKey]?.arrayValue else { return [] }
        return arr.compactMap { item in
            guard let port = item["port"]?.intValue, port > 0, port <= 65535,
                  let node = item["node"]?.stringValue, !node.isEmpty
            else { return nil }
            return FixedSocksBinding(port: UInt16(port), node: node, provider: item["provider"]?.stringValue)
        }
    }

    private func encodeFixedSocks(_ bindings: [FixedSocksBinding]) {
        rootConfig[Self.fixedSocksKey] = .array(bindings.map { binding in
            var obj: [String: JSONValue] = [
                "port": .int(Int64(binding.port)),
                "node": .string(binding.node),
            ]
            if let provider = binding.provider {
                obj["provider"] = .string(provider)
            }
            return .object(obj)
        })
    }

    private func resolveProviderURL(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return dataDirectory.appendingPathComponent(path)
    }

    private func readProviderNodes(path: String?, providerName: String) -> [ProxyNode] {
        guard let path else { return [] }
        let fileURL = resolveProviderURL(path)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        if let parsed = try? SimpleYAML.parse(text), let proxies = parsed["proxies"]?.arrayValue {
            return proxies.compactMap { item in
                guard let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
                return ProxyNode(name: name, type: item["type"]?.stringValue ?? "proxy", provider: providerName)
            }
        }
        if ShareLinkParser.looksLikeShareLinks(text), let links = try? ShareLinkParser.parseBundle(text) {
            return links.compactMap { item in
                guard let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
                return ProxyNode(name: name, type: item["type"]?.stringValue ?? "proxy", provider: providerName)
            }
        }
        return []
    }

    private func fileModificationDate(for path: String) -> Date? {
        let url = resolveProviderURL(path)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func makeUniqueName(_ base: String, existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func sanitizeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return str.isEmpty ? "subscription" : str
    }

    private func persist() throws {
        try Self.writeJSON(rootConfig, to: configURL)
    }

    private static func writeJSON(_ value: JSONValue, to url: URL) throws {
        let data = try value.prettyJSONData()
        try data.write(to: url, options: .atomic)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
