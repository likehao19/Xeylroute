import Foundation

public struct CoreStatus: Equatable, Sendable {
    public var dataDirectory: String
    public var coreAvailable: Bool
    public var configured: Bool
    public var running: Bool
    public var systemProxyEnabled: Bool
    public var tunEnabled: Bool
    public var tunScope: TunScope
    public var mixedPort: UInt16?
    public var httpPort: UInt16?
    public var socksPort: UInt16?
    public var coreVersionLabel: String

    public init(
        dataDirectory: String = "",
        coreAvailable: Bool = false,
        configured: Bool = false,
        running: Bool = false,
        systemProxyEnabled: Bool = false,
        tunEnabled: Bool = false,
        tunScope: TunScope = .all,
        mixedPort: UInt16? = nil,
        httpPort: UInt16? = nil,
        socksPort: UInt16? = nil,
        coreVersionLabel: String = "Mihomo"
    ) {
        self.dataDirectory = dataDirectory
        self.coreAvailable = coreAvailable
        self.configured = configured
        self.running = running
        self.systemProxyEnabled = systemProxyEnabled
        self.tunEnabled = tunEnabled
        self.tunScope = tunScope
        self.mixedPort = mixedPort
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.coreVersionLabel = coreVersionLabel
    }

    public var effectiveHTTPPort: UInt16? {
        if let httpPort, httpPort > 0 { return httpPort }
        if let mixedPort, mixedPort > 0 { return mixedPort }
        return nil
    }
}

public struct MihomoProxySnapshot: Equatable, Sendable {
    public var name: String
    public var type: String
    public var now: String?
    public var all: [String]
    public var latestDelay: Int?
    public var provider: String?

    public init(
        name: String,
        type: String,
        now: String? = nil,
        all: [String] = [],
        latestDelay: Int? = nil,
        provider: String? = nil
    ) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.latestDelay = latestDelay
        self.provider = provider
    }
}

public struct MihomoProviderSnapshot: Equatable, Sendable {
    public var name: String
    public var vehicleType: String?
    public var updatedAt: Date?
    public var usage: SubscriptionUsage?
    public var nodes: [ProxyNode]

    public init(
        name: String,
        vehicleType: String? = nil,
        updatedAt: Date? = nil,
        usage: SubscriptionUsage? = nil,
        nodes: [ProxyNode] = []
    ) {
        self.name = name
        self.vehicleType = vehicleType
        self.updatedAt = updatedAt
        self.usage = usage
        self.nodes = nodes
    }
}

public struct ConnectionTotals: Equatable, Sendable {
    public var downloadTotal: UInt64
    public var uploadTotal: UInt64
    public var activeCount: Int
    public var memoryBytes: UInt64

    public init(
        downloadTotal: UInt64 = 0,
        uploadTotal: UInt64 = 0,
        activeCount: Int = 0,
        memoryBytes: UInt64 = 0
    ) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.activeCount = activeCount
        self.memoryBytes = memoryBytes
    }
}

public struct MihomoSnapshot: Equatable, Sendable {
    public var mode: RoutingMode?
    public var mixedPort: UInt16?
    public var httpPort: UInt16?
    public var socksPort: UInt16?
    public var proxies: [String: MihomoProxySnapshot]
    public var providers: [String: MihomoProviderSnapshot]
    public var connections: ConnectionTotals?

    public init(
        mode: RoutingMode? = nil,
        mixedPort: UInt16? = nil,
        httpPort: UInt16? = nil,
        socksPort: UInt16? = nil,
        proxies: [String: MihomoProxySnapshot] = [:],
        providers: [String: MihomoProviderSnapshot] = [:],
        connections: ConnectionTotals? = nil
    ) {
        self.mode = mode
        self.mixedPort = mixedPort
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.proxies = proxies
        self.providers = providers
        self.connections = connections
    }
}

public struct DelayMeasurement: Equatable, Sendable {
    public var delayMs: Int?
    public var mbps: Double?
    public var error: String?
    public var measuredAt: Date

    public init(delayMs: Int? = nil, mbps: Double? = nil, error: String? = nil, measuredAt: Date = Date()) {
        self.delayMs = delayMs
        self.mbps = mbps
        self.error = error
        self.measuredAt = measuredAt
    }
}

public struct WebsiteProbeItem: Identifiable, Equatable, Sendable {
    public var id: String { host }
    public var name: String
    public var host: String
    public var category: String
    public var latencyMs: Int?
    public var httpStatus: Int?
    public var error: String?
    public var isTesting: Bool

    public init(
        name: String,
        host: String,
        category: String,
        latencyMs: Int? = nil,
        httpStatus: Int? = nil,
        error: String? = nil,
        isTesting: Bool = false
    ) {
        self.name = name
        self.host = host
        self.category = category
        self.latencyMs = latencyMs
        self.httpStatus = httpStatus
        self.error = error
        self.isTesting = isTesting
    }

    public static let defaultCatalog: [WebsiteProbeItem] = [
        WebsiteProbeItem(name: "Google", host: "www.google.com", category: "国际"),
        WebsiteProbeItem(name: "GitHub", host: "github.com", category: "开发"),
        WebsiteProbeItem(name: "YouTube", host: "www.youtube.com", category: "流媒体"),
        WebsiteProbeItem(name: "OpenAI", host: "chatgpt.com", category: "AI"),
        WebsiteProbeItem(name: "Claude", host: "claude.ai", category: "AI"),
        WebsiteProbeItem(name: "Apple", host: "www.apple.com", category: "国际"),
        WebsiteProbeItem(name: "Cloudflare", host: "www.cloudflare.com", category: "基础设施"),
        WebsiteProbeItem(name: "Bilibili", host: "www.bilibili.com", category: "国内"),
        WebsiteProbeItem(name: "知乎", host: "www.zhihu.com", category: "国内"),
        WebsiteProbeItem(name: "百度", host: "www.baidu.com", category: "国内"),
    ]
}

public struct ActiveRoute: Identifiable, Equatable, Sendable {
    public var id: String
    public var programPath: String
    public var processName: String
    public var host: String
    public var destinationIP: String
    public var port: String
    public var network: String
    public var inbound: String
    public var rule: String
    public var rulePayload: String
    public var chains: [String]

    public var displayTarget: String {
        let base = host.isEmpty ? destinationIP : host
        return port.isEmpty ? base : "\(base):\(port)"
    }

    public var displayApp: String {
        if !processName.isEmpty { return processName }
        if !programPath.isEmpty { return URL(fileURLWithPath: programPath).lastPathComponent }
        return "系统/未知"
    }

    public init(
        id: String = UUID().uuidString,
        programPath: String,
        processName: String,
        host: String,
        destinationIP: String,
        port: String,
        network: String,
        inbound: String,
        rule: String,
        rulePayload: String,
        chains: [String]
    ) {
        self.id = id
        self.programPath = programPath
        self.processName = processName
        self.host = host
        self.destinationIP = destinationIP
        self.port = port
        self.network = network
        self.inbound = inbound
        self.rule = rule
        self.rulePayload = rulePayload
        self.chains = chains
    }
}

public struct ConnectionLogRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var time: String
    public var app: String
    public var target: String
    public var protocolName: String
    public var exit: String
    public var decision: String
    public var failed: Bool

    public init(
        id: UUID = UUID(),
        time: String,
        app: String,
        target: String,
        protocolName: String,
        exit: String,
        decision: String,
        failed: Bool
    ) {
        self.id = id
        self.time = time
        self.app = app
        self.target = target
        self.protocolName = protocolName
        self.exit = exit
        self.decision = decision
        self.failed = failed
    }
}

public struct RunningProcess: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(pid):\(path)" }
    public var pid: Int32
    public var name: String
    public var executable: String
    public var path: String
    public var startedAt: String
    public var threadCount: Int

    public init(
        pid: Int32,
        name: String,
        executable: String,
        path: String,
        startedAt: String = "",
        threadCount: Int = 1
    ) {
        self.pid = pid
        self.name = name
        self.executable = executable
        self.path = path
        self.startedAt = startedAt
        self.threadCount = threadCount
    }
}

public struct GroupedRunningApp: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { primaryPath }
    public var name: String
    public var primaryPath: String
    public var bundlePath: String?
    public var paths: [String]
    public var members: [RunningProcess]

    public var instanceCount: Int { members.count }

    public init(
        name: String,
        primaryPath: String,
        bundlePath: String? = nil,
        paths: [String],
        members: [RunningProcess]
    ) {
        self.name = name
        self.primaryPath = primaryPath
        self.bundlePath = bundlePath
        self.paths = paths
        self.members = members
    }
}

public struct NetworkDetails: Equatable, Sendable {
    public var localAddresses: [String]
    public var dnsServers: [String]
    public var exitIP: String?
    public var error: String?

    public init(
        localAddresses: [String] = [],
        dnsServers: [String] = [],
        exitIP: String? = nil,
        error: String? = nil
    ) {
        self.localAddresses = localAddresses
        self.dnsServers = dnsServers
        self.exitIP = exitIP
        self.error = error
    }
}

public struct TrafficSample: Identifiable, Equatable, Sendable {
    public var id: Int
    public var timestamp: Date
    public var downloadBytesPerSec: Double
    public var uploadBytesPerSec: Double
    public var activeConnections: Int

    public init(
        id: Int,
        timestamp: Date = Date(),
        downloadBytesPerSec: Double,
        uploadBytesPerSec: Double,
        activeConnections: Int = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.downloadBytesPerSec = downloadBytesPerSec
        self.uploadBytesPerSec = uploadBytesPerSec
        self.activeConnections = activeConnections
    }
}
