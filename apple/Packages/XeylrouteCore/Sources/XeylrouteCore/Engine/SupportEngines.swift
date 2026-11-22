import Foundation

public enum RunningAppGrouper {
    public static func normalizePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    public static func macOSBundleRoot(for normalizedPath: String) -> String? {
        guard let range = normalizedPath.range(of: #"^.*?/[^/]+\.app/"#, options: .regularExpression) else {
            return nil
        }
        return String(normalizedPath[range])
    }

    private static func primaryRank(path: String, bundleRoot: String?) -> Int {
        guard let bundleRoot else { return 0 }
        let rel = String(path.dropFirst(bundleRoot.count))
        if rel.hasPrefix("contents/macos/") && !rel.contains("helper") { return 0 }
        if rel.hasPrefix("contents/macos/") { return 1 }
        if !rel.contains("/frameworks/") && !rel.contains("helper") { return 2 }
        return 3
    }

    /// Groups running processes by outermost `.app/` bundle or matching helper prefix.
    public static func group(_ processes: [RunningProcess]) -> [GroupedRunningApp] {
        var byPath: [String: [RunningProcess]] = [:]
        for proc in processes {
            let norm = normalizePath(proc.path)
            byPath[norm, default: []].append(proc)
        }

        struct ExecEntry {
            let normPath: String
            let members: [RunningProcess]
            let directory: String
            let stem: String
            let bundleRoot: String?
        }

        let executables: [ExecEntry] = byPath.map { normPath, members in
            let lastSlash = normPath.lastIndex(of: "/") ?? normPath.startIndex
            let dir = String(normPath[..<lastSlash])
            let file = String(normPath[normPath.index(after: lastSlash)...])
            let stem = file.hasSuffix(".exe") ? String(file.dropLast(4)) : file
            return ExecEntry(
                normPath: normPath,
                members: members,
                directory: dir,
                stem: stem,
                bundleRoot: macOSBundleRoot(for: normPath)
            )
        }

        var grouped: [String: [ExecEntry]] = [:]
        for entry in executables {
            let owner = entry.bundleRoot == nil
                ? executables
                    .filter { candidate in
                        candidate.bundleRoot == nil
                            && candidate.directory.hasSuffix("/" + candidate.stem)
                            && (entry.directory == candidate.directory || entry.directory.hasPrefix(candidate.directory + "/"))
                            && (entry.stem.hasPrefix(candidate.stem + "_") || entry.stem.hasPrefix(candidate.stem + "-"))
                    }
                    .sorted { $0.directory.count > $1.directory.count }
                    .first
                : nil
            let key = entry.bundleRoot ?? owner?.normPath ?? entry.normPath
            grouped[key, default: []].append(entry)
        }

        return grouped.map { owner, entries in
            let sorted = entries.sorted { lhs, rhs in
                let lOwner = lhs.normPath == owner ? 1 : 0
                let rOwner = rhs.normPath == owner ? 1 : 0
                if lOwner != rOwner { return lOwner > rOwner }
                let lRank = primaryRank(path: lhs.normPath, bundleRoot: lhs.bundleRoot)
                let rRank = primaryRank(path: rhs.normPath, bundleRoot: rhs.bundleRoot)
                if lRank != rRank { return lRank < rRank }
                if lhs.directory.count != rhs.directory.count { return lhs.directory.count < rhs.directory.count }
                if lhs.members.count != rhs.members.count { return lhs.members.count > rhs.members.count }
                return lhs.normPath < rhs.normPath
            }
            let primary = sorted[0].members[0]
            let allMembers = sorted.flatMap(\.members)
            let rawBundlePath: String? = sorted[0].bundleRoot.flatMap { root in
                let count = root.count - 1 // drop trailing slash
                return primary.path.count >= count ? String(primary.path.prefix(count)) : nil
            }
            let displayName: String
            if let rawBundlePath {
                displayName = URL(fileURLWithPath: rawBundlePath).deletingPathExtension().lastPathComponent
            } else {
                displayName = primary.name
            }
            return GroupedRunningApp(
                name: displayName,
                primaryPath: primary.path,
                bundlePath: rawBundlePath,
                paths: sorted.map { $0.members[0].path },
                members: allMembers
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public enum ConnectionLogParser {
    private static let internalProbeGroup = "RoutePilot.Internal.SpeedTest"

    public static func parse(structuredJSONLine data: Data) -> ConnectionLogRow? {
        guard let json = try? JSONValue.decode(from: data),
              let message = json["message"]?.stringValue,
              let time = json["time"]?.stringValue
        else {
            return nil
        }
        return parse(time: time, message: message)
    }

    public static func parse(time: String, message: String) -> ConnectionLogRow? {
        guard message.hasPrefix("["),
              let closeRange = message.range(of: "] ")
        else { return nil }
        let proto = String(message[message.index(after: message.startIndex)..<closeRange.lowerBound])
        guard proto == "TCP" || proto == "UDP" else { return nil }
        let route = String(message[closeRange.upperBound...])
        guard let arrowRange = route.range(of: " --> ") else { return nil }
        let rawSource = String(route[..<arrowRange.lowerBound])
        let right = String(route[arrowRange.upperBound...])
        guard let spaceIdx = right.firstIndex(of: " ") else { return nil }
        let target = String(right[..<spaceIdx])
        let rest = String(right[right.index(after: spaceIdx)...])

        let source: String
        let exit: String
        let decision: String
        let failed: Bool

        if rest.hasPrefix("error: ") {
            let errText = String(rest.dropFirst("error: ".count))
            guard rawSource.hasPrefix("dial ") else { return nil }
            let attempt = String(rawSource.dropFirst("dial ".count))
            let originEnd: String.Index
            if attempt.hasSuffix(")"), let paren = attempt.lastIndex(of: "(") {
                originEnd = paren
            } else {
                originEnd = attempt.endIndex
            }
            guard let originStart = attempt[..<originEnd].lastIndex(of: " ") else { return nil }
            let exitPart = String(attempt[..<originStart])
            source = String(attempt[attempt.index(after: originStart)...])
            if let matchRange = exitPart.range(of: " (match ") {
                exit = String(exitPart[..<matchRange.lowerBound])
                let rule = String(exitPart[matchRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ")"))
                decision = rule.isEmpty ? errText : "\(rule) · \(errText)"
            } else {
                exit = exitPart
                decision = errText
            }
            failed = true
        } else {
            guard let usingRange = rest.range(of: "using ") else { return nil }
            source = rawSource
            exit = String(rest[usingRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            var matchStr = String(rest[..<usingRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if matchStr.hasPrefix("match ") {
                matchStr = String(matchStr.dropFirst("match ".count))
            }
            decision = matchStr
            failed = false
        }

        if exit.contains(internalProbeGroup) {
            return nil
        }

        var appName = ""
        if let parenStart = source.firstIndex(of: "("), source.hasSuffix(")") {
            let rawName = String(source[source.index(after: parenStart)..<source.index(before: source.endIndex)])
            let clean = rawName.components(separatedBy: ", uid=").first ?? rawName
            if !clean.hasPrefix("uid=") {
                appName = clean
            }
        }

        return ConnectionLogRow(
            time: time,
            app: appName,
            target: target,
            protocolName: proto,
            exit: exit,
            decision: decision,
            failed: failed
        )
    }
}

public enum ProbeQueue {
    /// Executes async work over `items` with at most `concurrency` in-flight tasks.
    public static func run<Item: Sendable>(
        items: [Item],
        concurrency: Int,
        operation: @escaping @Sendable (Item) async -> Void
    ) async {
        let limit = max(1, min(concurrency, items.count))
        guard !items.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            for _ in 0..<limit {
                let item = items[nextIndex]
                nextIndex += 1
                group.addTask { await operation(item) }
            }
            while await group.next() != nil {
                if Task.isCancelled { break }
                if nextIndex < items.count {
                    let item = items[nextIndex]
                    nextIndex += 1
                    group.addTask { await operation(item) }
                }
            }
        }
    }
}

public struct TrafficTracker: Sendable {
    public private(set) var samples: [TrafficSample] = []
    private var previousDownload: UInt64?
    private var previousUpload: UInt64?
    private var previousTimestamp: Date?
    private var nextID: Int = 0
    private let maxSamples: Int

    public init(maxSamples: Int = 60) {
        self.maxSamples = maxSamples
    }

    public mutating func reset() {
        previousDownload = nil
        previousUpload = nil
        previousTimestamp = nil
        samples.removeAll()
    }

    public mutating func record(totals: ConnectionTotals?, at now: Date = Date()) -> (down: Double, up: Double) {
        guard let totals else {
            previousDownload = nil
            previousUpload = nil
            previousTimestamp = nil
            return (0, 0)
        }
        defer {
            previousDownload = totals.downloadTotal
            previousUpload = totals.uploadTotal
            previousTimestamp = now
        }
        guard let prevDown = previousDownload,
              let prevUp = previousUpload,
              let prevTime = previousTimestamp
        else {
            return (0, 0)
        }
        let dt = now.timeIntervalSince(prevTime)
        guard dt > 0.05, totals.downloadTotal >= prevDown, totals.uploadTotal >= prevUp else {
            return (0, 0)
        }
        let downRate = Double(totals.downloadTotal - prevDown) / dt
        let upRate = Double(totals.uploadTotal - prevUp) / dt
        nextID += 1
        samples.append(TrafficSample(
            id: nextID,
            timestamp: now,
            downloadBytesPerSec: downRate,
            uploadBytesPerSec: upRate,
            activeConnections: totals.activeCount
        ))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        return (downRate, upRate)
    }

    public static func formatRate(_ bytesPerSec: Double) -> String {
        guard bytesPerSec.isFinite, bytesPerSec > 0 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSec
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value.rounded())) \(units[unitIndex])"
        }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unitIndex])
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.2f %@", value, units[unitIndex])
    }
}
