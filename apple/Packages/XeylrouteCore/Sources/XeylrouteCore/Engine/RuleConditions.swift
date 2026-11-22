import Foundation
import Darwin

public enum RuleConditionError: LocalizedError, Equatable, Sendable {
    case invalidProgramPath
    case unbalancedParentheses
    case invalidURL
    case unsupportedURLScheme
    case missingHostname
    case invalidPrefix
    case prefixOutOfRange
    case invalidTarget
    case invalidPort
    case emptyConditions

    public var errorDescription: String? {
        switch self {
        case .invalidProgramPath:
            return "请选择有效的可执行文件绝对路径"
        case .unbalancedParentheses:
            return "内核组合规则要求程序路径中的括号成对出现"
        case .invalidURL:
            return "网址无效"
        case .unsupportedURLScheme:
            return "请输入 HTTP 或 HTTPS 网址"
        case .missingHostname:
            return "网址缺少主机名"
        case .invalidPrefix:
            return "网段前缀无效"
        case .prefixOutOfRange:
            return "网段前缀超出范围"
        case .invalidTarget:
            return "请输入域名、IP 地址或 CIDR 网段"
        case .invalidPort:
            return "端口须为 1–65535，范围按从小到大填写"
        case .emptyConditions:
            return "请填写匹配条件；所有连接的出口请在「未命中规则时」设置"
        }
    }
}

public enum RuleConditionsEngine {
    /// Compiles structured conditions into a Mihomo `(kind, payload)` rule pair.
    public static func compile(_ conditions: RuleConditions) throws -> (kind: String, payload: String) {
        var parts: [(String, String)] = []
        let path = conditions.program.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            let hasControl = path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            if !path.hasPrefix("/") || path.contains(",") || hasControl {
                throw RuleConditionError.invalidProgramPath
            }
            parts.append(("PROCESS-PATH", path))
        }

        let target = conditions.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty {
            parts.append(try compileTarget(target, suffix: conditions.suffix))
        }

        let port = conditions.port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !port.isEmpty {
            let pair = port.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let startStr = String(pair[0])
            let endStr = pair.count == 2 ? String(pair[1]) : startStr
            guard
                let a = UInt16(startStr), a > 0,
                let b = UInt16(endStr), b > 0,
                a <= b
            else {
                throw RuleConditionError.invalidPort
            }
            parts.append(("DST-PORT", a == b ? "\(a)" : "\(a)-\(b)"))
        }

        switch parts.count {
        case 0:
            throw RuleConditionError.emptyConditions
        case 1:
            return parts[0]
        default:
            var depth = 0
            for ch in path {
                if ch == "(" { depth += 1 }
                if ch == ")" { depth -= 1 }
                if depth < 0 { break }
            }
            if depth != 0 {
                throw RuleConditionError.unbalancedParentheses
            }
            let clauses = parts.map { "(\($0.0),\($0.1))" }.joined(separator: ",")
            return ("AND", "(\(clauses))")
        }
    }

    /// Decodes a Mihomo rule back into `RuleConditions` only when representation is lossless.
    public static func decode(kind: String, payload: String) -> RuleConditions? {
        var conditions = RuleConditions()

        func ingest(_ k: String, _ value: String) -> Bool {
            switch k {
            case "PROCESS-PATH" where conditions.program.isEmpty:
                conditions.program = value
                return true
            case "DOMAIN", "DOMAIN-SUFFIX", "IP-CIDR", "IP-CIDR6":
                guard conditions.target.isEmpty else { return false }
                conditions.target = value
                conditions.suffix = (k == "DOMAIN-SUFFIX")
                return true
            case "DST-PORT" where conditions.port.isEmpty:
                conditions.port = value
                return true
            default:
                return false
            }
        }

        if kind == "AND" {
            guard payload.hasPrefix("(("), payload.hasSuffix("))") else { return nil }
            let inner = String(payload.dropFirst(2).dropLast(2))
            for clause in inner.components(separatedBy: "),(") {
                guard let comma = clause.firstIndex(of: ",") else { return nil }
                let k = String(clause[..<comma])
                let v = String(clause[clause.index(after: comma)...])
                if !ingest(k, v) { return nil }
            }
        } else if !ingest(kind, payload) {
            return nil
        }

        guard let recompiled = try? compile(conditions), recompiled.kind == kind, recompiled.payload == payload else {
            return nil
        }
        return conditions
    }

    /// Parses a full Mihomo rule line into `(kind, payload, exit)`.
    public static func parseRuleLine(_ line: String) -> (kind: String, payload: String, exit: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let firstComma = trimmed.firstIndex(of: ",") else { return nil }
        let kind = String(trimmed[..<firstComma]).trimmingCharacters(in: .whitespaces)
        let rest = String(trimmed[trimmed.index(after: firstComma)...])
        if kind.uppercased() == "MATCH" {
            return ("MATCH", "", rest.trimmingCharacters(in: .whitespaces))
        }
        // Handle AND(((...)),EXIT) or IP-CIDR,1.2.3.4/32,EXIT,no-resolve
        var segments: [String] = []
        var current = ""
        var depth = 0
        for ch in rest {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth = max(0, depth - 1) }
            if ch == "," && depth == 0 {
                segments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        segments.append(current.trimmingCharacters(in: .whitespaces))
        guard segments.count >= 2 else { return nil }
        return (kind, segments[0], segments[1])
    }

    public static func formatRuleLine(kind: String, payload: String, exit: String) -> String {
        if kind.uppercased() == "MATCH" {
            return "MATCH,\(exit)"
        }
        if kind == "IP-CIDR" || kind == "IP-CIDR6" {
            return "\(kind),\(payload),\(exit),no-resolve"
        }
        return "\(kind),\(payload),\(exit)"
    }

    public static func compileTarget(_ raw: String, suffix: Bool) throws -> (String, String) {
        let host: String
        if raw.contains("://") {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
                throw RuleConditionError.invalidURL
            }
            guard scheme == "http" || scheme == "https" else {
                throw RuleConditionError.unsupportedURLScheme
            }
            guard let extracted = url.host, !extracted.isEmpty else {
                throw RuleConditionError.missingHostname
            }
            host = extracted
        } else {
            host = raw
        }

        let split = host.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var address = String(split[0])
        let prefixStr = split.count == 2 ? String(split[1]) : nil
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }

        if let ipv4 = parseIPv4(address) {
            let bits = try parsePrefix(prefixStr, maxBits: 32)
            let masked = maskIPv4(ipv4, bits: bits)
            return ("IP-CIDR", "\(formatIPv4(masked))/\(bits)")
        }

        if let ipv6 = parseIPv6(address) {
            let bits = try parsePrefix(prefixStr, maxBits: 128)
            let masked = maskIPv6(ipv6, bits: bits)
            return ("IP-CIDR6", "\(formatIPv6(masked))/\(bits)")
        }

        if prefixStr != nil {
            throw RuleConditionError.invalidTarget
        }

        let domain = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let allDigitsAndDots = domain.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 46 }
        let validLabels = !labels.isEmpty && labels.allSatisfy { label in
            !label.isEmpty
                && label.count <= 63
                && !label.hasPrefix("-")
                && !label.hasSuffix("-")
                && label.utf8.allSatisfy {
                    ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
                }
        }
        if domain.isEmpty || domain.count > 253 || allDigitsAndDots || !validLabels {
            throw RuleConditionError.invalidTarget
        }
        return (suffix ? "DOMAIN-SUFFIX" : "DOMAIN", domain)
    }

    private static func parsePrefix(_ str: String?, maxBits: UInt8) throws -> UInt8 {
        guard let str else { return maxBits }
        guard let bits = UInt8(str) else { throw RuleConditionError.invalidPrefix }
        if bits > maxBits { throw RuleConditionError.prefixOutOfRange }
        return bits
    }

    private static func parseIPv4(_ str: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, str, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func maskIPv4(_ value: UInt32, bits: UInt8) -> UInt32 {
        if bits == 0 { return 0 }
        let mask = UInt32.max << (32 - bits)
        return value & mask
    }

    private static func formatIPv4(_ value: UInt32) -> String {
        var addr = in_addr(s_addr: value.bigEndian)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func parseIPv6(_ str: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, str, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    private static func maskIPv6(_ bytes: [UInt8], bits: UInt8) -> [UInt8] {
        var result = bytes
        let fullBytes = Int(bits / 8)
        let remBits = Int(bits % 8)
        for idx in 0..<result.count {
            if idx < fullBytes {
                continue
            } else if idx == fullBytes, remBits > 0 {
                let mask = UInt8(0xFF) << (8 - remBits)
                result[idx] &= mask
            } else {
                result[idx] = 0
            }
        }
        return result
    }

    private static func formatIPv6(_ bytes: [UInt8]) -> String {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { ptr in
            ptr.copyBytes(from: bytes.prefix(16))
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
