import Foundation

/// Lightweight, zero-dependency YAML subset parser and serializer covering Clash/Mihomo profiles
/// (nested mappings, sequences, inline flow maps/lists `{...}` / `[...]`, quoted & scalar values).
public enum SimpleYAML {
    public enum ParseError: LocalizedError, Sendable {
        case invalidSyntax(Int, String)

        public var errorDescription: String? {
            switch self {
            case .invalidSyntax(let line, let detail):
                return "YAML 第 \(line) 行格式错误：\(detail)"
            }
        }
    }

    private struct Line {
        let number: Int
        let indent: Int
        let text: String
    }

    public static func parse(_ source: String) throws -> JSONValue {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8), let json = try? JSONValue.decode(from: data) {
                return json
            }
        }

        let lines = preprocess(source)
        guard !lines.isEmpty else { return .object([:]) }
        var index = 0
        return try parseBlock(lines, index: &index, minIndent: lines[0].indent)
    }

    public static func emit(_ value: JSONValue, indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return "\(i)"
        case .double(let d):
            return "\(d)"
        case .string(let s):
            return escapeScalar(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            return items.map { item in
                switch item {
                case .object(let dict) where !dict.isEmpty:
                    let keys = dict.keys.sorted()
                    var lines: [String] = []
                    for (idx, key) in keys.enumerated() {
                        let prefix = idx == 0 ? "\(pad)- " : "\(pad)  "
                        lines.append(formatKeyValue(key: key, value: dict[key] ?? .null, prefix: prefix, childIndent: indent + 4))
                    }
                    return lines.joined(separator: "\n")
                case .array(let nested) where !nested.isEmpty:
                    return "\(pad)-\n\(emit(item, indent: indent + 2))"
                default:
                    return "\(pad)- \(emit(item, indent: indent + 2))"
                }
            }.joined(separator: "\n")
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            return dict.keys.sorted().map { key in
                formatKeyValue(key: key, value: dict[key] ?? .null, prefix: pad, childIndent: indent + 2)
            }.joined(separator: "\n")
        }
    }

    private static func formatKeyValue(key: String, value: JSONValue, prefix: String, childIndent: Int) -> String {
        let k = escapeKey(key)
        switch value {
        case .object(let dict) where !dict.isEmpty:
            return "\(prefix)\(k):\n\(emit(value, indent: childIndent))"
        case .array(let items) where !items.isEmpty:
            return "\(prefix)\(k):\n\(emit(value, indent: childIndent))"
        default:
            return "\(prefix)\(k): \(emit(value, indent: childIndent))"
        }
    }

    private static func preprocess(_ source: String) -> [Line] {
        var result: [Line] = []
        let rawLines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (idx, raw) in rawLines.enumerated() {
            let stripped = stripComment(raw)
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" || trimmed == "..." { continue }
            let indent = stripped.prefix { $0 == " " }.count
            result.append(Line(number: idx + 1, indent: indent, text: trimmed))
        }
        return result
    }

    private static func parseBlock(_ lines: [Line], index: inout Int, minIndent: Int) throws -> JSONValue {
        guard index < lines.count else { return .null }
        if lines[index].text.hasPrefix("- ") || lines[index].text == "-" {
            return try parseSequence(lines, index: &index, baseIndent: lines[index].indent)
        }
        return try parseMapping(lines, index: &index, baseIndent: lines[index].indent)
    }

    private static func parseSequence(_ lines: [Line], index: inout Int, baseIndent: Int) throws -> JSONValue {
        var items: [JSONValue] = []
        while index < lines.count {
            let line = lines[index]
            if line.indent < baseIndent { break }
            if line.indent > baseIndent { break }
            guard line.text == "-" || line.text.hasPrefix("- ") else { break }

            let rest = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1

            if rest.isEmpty {
                if index < lines.count, lines[index].indent > baseIndent {
                    items.append(try parseBlock(lines, index: &index, minIndent: lines[index].indent))
                } else {
                    items.append(.null)
                }
            } else if rest.hasPrefix("{") || rest.hasPrefix("[") {
                items.append(try parseInlineValue(rest, lineNumber: line.number))
            } else if let (k, v) = splitKeyValue(rest) {
                var dict: [String: JSONValue] = [:]
                if v.isEmpty {
                    if index < lines.count, lines[index].indent > baseIndent + 2 {
                        dict[k] = try parseBlock(lines, index: &index, minIndent: lines[index].indent)
                    } else {
                        dict[k] = .null
                    }
                } else {
                    dict[k] = try parseInlineValue(v, lineNumber: line.number)
                }
                let itemIndent = baseIndent + 2
                while index < lines.count, lines[index].indent >= itemIndent {
                    let sub = lines[index]
                    if sub.indent == itemIndent, (sub.text == "-" || sub.text.hasPrefix("- ")) { break }
                    guard let (sk, sv) = splitKeyValue(sub.text) else {
                        index += 1
                        continue
                    }
                    index += 1
                    if sv.isEmpty {
                        if index < lines.count, lines[index].indent > sub.indent {
                            dict[sk] = try parseBlock(lines, index: &index, minIndent: lines[index].indent)
                        } else {
                            dict[sk] = .null
                        }
                    } else {
                        dict[sk] = try parseInlineValue(sv, lineNumber: sub.number)
                    }
                }
                items.append(.object(dict))
            } else {
                items.append(try parseInlineValue(rest, lineNumber: line.number))
            }
        }
        return .array(items)
    }

    private static func parseMapping(_ lines: [Line], index: inout Int, baseIndent: Int) throws -> JSONValue {
        var dict: [String: JSONValue] = [:]
        while index < lines.count {
            let line = lines[index]
            if line.indent < baseIndent { break }
            if line.indent > baseIndent { break }
            if line.text == "-" || line.text.hasPrefix("- ") { break }
            guard let (key, rawVal) = splitKeyValue(line.text) else {
                throw ParseError.invalidSyntax(line.number, "缺少键值分隔符 ':'")
            }
            index += 1
            if rawVal.isEmpty {
                if index < lines.count, lines[index].indent > baseIndent {
                    dict[key] = try parseBlock(lines, index: &index, minIndent: lines[index].indent)
                } else if index < lines.count, lines[index].indent == baseIndent,
                          (lines[index].text == "-" || lines[index].text.hasPrefix("- "))
                {
                    dict[key] = try parseSequence(lines, index: &index, baseIndent: baseIndent)
                } else {
                    dict[key] = .null
                }
            } else {
                dict[key] = try parseInlineValue(rawVal, lineNumber: line.number)
            }
        }
        return .object(dict)
    }

    private static func parseInlineValue(_ raw: String, lineNumber: Int) throws -> JSONValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "null" || s == "~" { return .null }
        if s == "true" || s == "True" || s == "TRUE" { return .bool(true) }
        if s == "false" || s == "False" || s == "FALSE" { return .bool(false) }

        if s.hasPrefix("{"), s.hasSuffix("}") {
            let inner = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .object([:]) }
            var dict: [String: JSONValue] = [:]
            for part in splitFlow(inner) {
                guard let (k, v) = splitKeyValue(part) else {
                    throw ParseError.invalidSyntax(lineNumber, "行内对象格式无效")
                }
                dict[k] = try parseInlineValue(v, lineNumber: lineNumber)
            }
            return .object(dict)
        }

        if s.hasPrefix("["), s.hasSuffix("]") {
            let inner = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .array([]) }
            return .array(try splitFlow(inner).map { try parseInlineValue($0, lineNumber: lineNumber) })
        }

        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return .string(unquote(s))
        }
        if let i = Int64(s) { return .int(i) }
        if let d = Double(s) { return .double(d) }
        return .string(s)
    }

    private static func splitKeyValue(_ text: String) -> (String, String)? {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var braceDepth = 0
        var bracketDepth = 0

        for idx in text.indices {
            let ch = text[idx]
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && inDouble {
                escaped = true
                continue
            }
            if ch == "'" && !inDouble { inSingle.toggle(); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); continue }
            if !inSingle && !inDouble {
                if ch == "{" { braceDepth += 1 }
                else if ch == "}" { braceDepth = max(0, braceDepth - 1) }
                else if ch == "[" { bracketDepth += 1 }
                else if ch == "]" { bracketDepth = max(0, bracketDepth - 1) }
                else if ch == ":" && braceDepth == 0 && bracketDepth == 0 {
                    let nextIdx = text.index(after: idx)
                    if nextIdx == text.endIndex || text[nextIdx] == " " || text[nextIdx] == "\t" {
                        let rawKey = String(text[..<idx]).trimmingCharacters(in: .whitespaces)
                        let val = nextIdx == text.endIndex ? "" : String(text[nextIdx...]).trimmingCharacters(in: .whitespaces)
                        return (unquote(rawKey), val)
                    }
                }
            }
        }
        return nil
    }

    private static func splitFlow(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        var depth = 0

        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inDouble {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "'" && !inDouble { inSingle.toggle(); current.append(ch); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); current.append(ch); continue }
            if !inSingle && !inDouble {
                if ch == "{" || ch == "[" { depth += 1 }
                else if ch == "}" || ch == "]" { depth = max(0, depth - 1) }
                else if ch == "," && depth == 0 {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { parts.append(trimmed) }
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    private static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var previousWasSpace = true

        for idx in line.indices {
            let ch = line[idx]
            if escaped {
                escaped = false
                previousWasSpace = false
                continue
            }
            if ch == "\\" && inDouble {
                escaped = true
                previousWasSpace = false
                continue
            }
            if ch == "'" && !inDouble { inSingle.toggle(); previousWasSpace = false; continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); previousWasSpace = false; continue }
            if !inSingle && !inDouble && ch == "#" && previousWasSpace {
                return String(line[..<idx])
            }
            previousWasSpace = ch == " " || ch == "\t"
        }
        return line
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if s.hasPrefix("\""), s.hasSuffix("\"") {
            let inner = String(s.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return s
    }

    private static func escapeKey(_ key: String) -> String {
        let safe = key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
        return (!key.isEmpty && safe) ? key : escapeScalar(key)
    }

    private static func escapeScalar(_ value: String) -> String {
        let needsQuotes = value.isEmpty
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || ["true", "false", "null", "~", "yes", "no"].contains(value.lowercased())
            || Int64(value) != nil || Double(value) != nil
            || value.contains(where: { ":{}[]#,&*!|>'\"%@`\n\r\t".contains($0) })
        if !needsQuotes { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
