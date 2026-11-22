import Foundation

public enum RoutingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case rule
    case global
    case direct

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rule: return "规则"
        case .global: return "全局"
        case .direct: return "直连"
        }
    }

    public var fullTitle: String {
        switch self {
        case .rule: return "规则模式"
        case .global: return "全局模式"
        case .direct: return "直连模式"
        }
    }
}

public enum TunScope: String, Codable, CaseIterable, Sendable, Identifiable {
    case all
    case selected

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部受支持流量"
        case .selected: return "仅指定分组和程序"
        }
    }
}

public enum ProbeService: String, Codable, CaseIterable, Sendable, Identifiable {
    case google
    case cloudflare
    case microsoft

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .google: return "Google"
        case .cloudflare: return "Cloudflare"
        case .microsoft: return "Microsoft"
        }
    }

    public var urlString: String {
        switch self {
        case .google: return "https://www.gstatic.com/generate_204"
        case .cloudflare: return "https://cp.cloudflare.com/generate_204"
        case .microsoft: return "http://www.msftconnecttest.com/connecttest.txt"
        }
    }
}

public struct CoreSettings: Codable, Equatable, Sendable {
    public var ipv6: Bool
    public var tcpConcurrent: Bool
    public var unifiedDelay: Bool
    public var logLevel: String

    enum CodingKeys: String, CodingKey {
        case ipv6
        case tcpConcurrent = "tcp-concurrent"
        case unifiedDelay = "unified-delay"
        case logLevel = "log-level"
    }

    public init(
        ipv6: Bool = false,
        tcpConcurrent: Bool = true,
        unifiedDelay: Bool = true,
        logLevel: String = "info"
    ) {
        self.ipv6 = ipv6
        self.tcpConcurrent = tcpConcurrent
        self.unifiedDelay = unifiedDelay
        self.logLevel = logLevel
    }
}

public struct FixedSocksBinding: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var port: UInt16
    public var node: String
    public var provider: String?

    public var id: String { "\(port)|\(provider ?? "")|\(node)" }

    public init(port: UInt16, node: String, provider: String? = nil) {
        self.port = port
        self.node = node
        self.provider = provider
    }
}

public struct RuleConditions: Codable, Equatable, Hashable, Sendable {
    public var program: String
    public var target: String
    public var suffix: Bool
    public var port: String

    public init(program: String = "", target: String = "", suffix: Bool = false, port: String = "") {
        self.program = program
        self.target = target
        self.suffix = suffix
        self.port = port
    }

    public var isEmpty: Bool {
        program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct ProfileRule: Identifiable, Equatable, Hashable, Sendable {
    public var index: Int
    public var rawLine: String
    public var kind: String
    public var payload: String
    public var exit: String
    public var enabled: Bool
    public var isShared: Bool
    public var conditions: RuleConditions?

    public var id: String { "\(index):\(rawLine)" }

    public var isDefaultMatch: Bool {
        kind.uppercased() == "MATCH"
    }

    public init(
        index: Int,
        rawLine: String,
        kind: String,
        payload: String,
        exit: String,
        enabled: Bool,
        isShared: Bool = false,
        conditions: RuleConditions? = nil
    ) {
        self.index = index
        self.rawLine = rawLine
        self.kind = kind
        self.payload = payload
        self.exit = exit
        self.enabled = enabled
        self.isShared = isShared
        self.conditions = conditions
    }
}

public struct PolicyGroup: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String
    public var proxies: [String]
    public var use: [String]
    public var enabled: Bool

    public var id: String { name }

    public init(
        name: String,
        type: String = "select",
        proxies: [String] = [],
        use: [String] = [],
        enabled: Bool = true
    ) {
        self.name = name
        self.type = type
        self.proxies = proxies
        self.use = use
        self.enabled = enabled
    }
}

public struct SubscriptionProvider: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String // "http" or "file"
    public var interval: Int
    public var url: String?
    public var path: String?
    public var updatedAt: Date?
    public var usage: SubscriptionUsage?
    public var nodes: [ProxyNode]
    public var lastError: String?

    public var id: String { name }

    public var isRemote: Bool { type == "http" }

    public init(
        name: String,
        type: String,
        interval: Int = 3600,
        url: String? = nil,
        path: String? = nil,
        updatedAt: Date? = nil,
        usage: SubscriptionUsage? = nil,
        nodes: [ProxyNode] = [],
        lastError: String? = nil
    ) {
        self.name = name
        self.type = type
        self.interval = interval
        self.url = url
        self.path = path
        self.updatedAt = updatedAt
        self.usage = usage
        self.nodes = nodes
        self.lastError = lastError
    }
}

public struct SubscriptionUsage: Codable, Equatable, Hashable, Sendable {
    public var upload: Int64
    public var download: Int64
    public var total: Int64
    public var expire: Int64?

    enum CodingKeys: String, CodingKey {
        case upload = "Upload"
        case download = "Download"
        case total = "Total"
        case expire = "Expire"
    }

    public init(upload: Int64 = 0, download: Int64 = 0, total: Int64 = 0, expire: Int64? = nil) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    public var used: Int64 { max(0, upload) + max(0, download) }

    public var progress: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(used) / Double(total))
    }

    public var expireDate: Date? {
        guard let expire, expire > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expire))
    }
}

public struct ProxyNode: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String
    public var provider: String?
    public var isPolicy: Bool
    public var currentSelection: String?

    public var id: String { "\(provider ?? "standalone")|\(name)" }

    public init(
        name: String,
        type: String,
        provider: String? = nil,
        isPolicy: Bool = false,
        currentSelection: String? = nil
    ) {
        self.name = name
        self.type = type
        self.provider = provider
        self.isPolicy = isPolicy
        self.currentSelection = currentSelection
    }
}

public struct ProfileSummary: Equatable, Sendable {
    public var mode: RoutingMode
    public var mixedPort: UInt16
    public var httpPort: UInt16
    public var socksPort: UInt16
    public var coreSettings: CoreSettings
    public var tunScope: TunScope
    public var subscriptionScope: String?
    public var rules: [ProfileRule]
    public var effectiveRules: [String]
    public var manualOrder: Bool
    public var groups: [PolicyGroup]
    public var providers: [SubscriptionProvider]
    public var standaloneNodes: [ProxyNode]
    public var exits: [String]
    public var fixedSocks: [FixedSocksBinding]
    public var fallbackToDirect: Bool

    public var isConfigured: Bool {
        !providers.isEmpty || !standaloneNodes.isEmpty || !rules.filter { !$0.isDefaultMatch }.isEmpty
    }

    public init(
        mode: RoutingMode = .rule,
        mixedPort: UInt16 = 7890,
        httpPort: UInt16 = 0,
        socksPort: UInt16 = 0,
        coreSettings: CoreSettings = CoreSettings(),
        tunScope: TunScope = .all,
        subscriptionScope: String? = nil,
        rules: [ProfileRule] = [],
        effectiveRules: [String] = [],
        manualOrder: Bool = false,
        groups: [PolicyGroup] = [],
        providers: [SubscriptionProvider] = [],
        standaloneNodes: [ProxyNode] = [],
        exits: [String] = ["DIRECT", "REJECT", "AUTO"],
        fixedSocks: [FixedSocksBinding] = [],
        fallbackToDirect: Bool = true
    ) {
        self.mode = mode
        self.mixedPort = mixedPort
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.coreSettings = coreSettings
        self.tunScope = tunScope
        self.subscriptionScope = subscriptionScope
        self.rules = rules
        self.effectiveRules = effectiveRules
        self.manualOrder = manualOrder
        self.groups = groups
        self.providers = providers
        self.standaloneNodes = standaloneNodes
        self.exits = exits
        self.fixedSocks = fixedSocks
        self.fallbackToDirect = fallbackToDirect
    }
}
