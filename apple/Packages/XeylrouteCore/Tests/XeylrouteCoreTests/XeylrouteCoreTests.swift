import Foundation
import Testing
@testable import XeylrouteCore

@Suite("XeylrouteCore Tests")
struct XeylrouteCoreTests {
    @Test("Compound rule conditions compile and round-trip losslessly")
    func ruleConditionsRoundTrip() throws {
        let cond = RuleConditions(
            program: "/Applications/Example (ARM64)/Client",
            target: "https://corp.example/path",
            suffix: false,
            port: "440-443"
        )
        let compiled = try RuleConditionsEngine.compile(cond)
        #expect(compiled.kind == "AND")
        #expect(compiled.payload == "((PROCESS-PATH,/Applications/Example (ARM64)/Client),(DOMAIN,corp.example),(DST-PORT,440-443))")

        let decoded = RuleConditionsEngine.decode(kind: compiled.kind, payload: compiled.payload)
        #expect(decoded?.program == cond.program)
        #expect(decoded?.target == "corp.example")
        #expect(decoded?.port == "440-443")

        let ipv4 = try RuleConditionsEngine.compileTarget("192.0.2.1", suffix: false)
        #expect(ipv4.0 == "IP-CIDR")
        #expect(ipv4.1 == "192.0.2.1/32")

        let ipv6 = try RuleConditionsEngine.compileTarget("2001:db8::1/64", suffix: false)
        #expect(ipv6.0 == "IP-CIDR6")
        #expect(ipv6.1 == "2001:db8::/64")

        let unbalanced = RuleConditions(program: "/opt/Bad )(/bin", port: "443")
        #expect(throws: RuleConditionError.unbalancedParentheses) {
            _ = try RuleConditionsEngine.compile(unbalanced)
        }
    }

    @Test("Share links parser handles VLESS Reality, Trojan, Hysteria2, SS, VMess, and Base64 bundles")
    func shareLinkParsing() throws {
        let vless = "vless://11111111-1111-1111-1111-111111111111@example.com:443?security=reality&sni=www.apple.com&fp=chrome&pbk=PUBKEY&sid=abcd&type=tcp&flow=xtls-rprx-vision#Tokyo%20VLESS"
        let trojan = "trojan://secret@hk.example.com:443?sni=hk.example.com&type=ws&path=%2Fws#HK%20Trojan"
        let hy2 = "hy2://pass123@sg.example.com:8443?sni=sg.example.com&insecure=1#SG%20Hy2"
        let ssCred = Data("aes-256-gcm:my-pass".utf8).base64EncodedString()
        let ss = "ss://\(ssCred)@jp.example.com:8388#JP%20SS"
        let vmessJSON = #"{"v":"2","ps":"US VMess","add":"us.example.com","port":"443","id":"22222222-2222-2222-2222-222222222222","aid":"0","net":"ws","tls":"tls","host":"us.example.com","path":"/v"}"#
        let vmess = "vmess://\(Data(vmessJSON.utf8).base64EncodedString())"

        let combined = [vless, trojan, hy2, ss, vmess].joined(separator: "\n")
        #expect(ShareLinkParser.looksLikeShareLinks(combined))

        let nodes = try ShareLinkParser.parseBundle(combined, requireAll: true)
        #expect(nodes.count == 5)
        #expect(nodes[0]["name"]?.stringValue == "Tokyo VLESS")
        #expect(nodes[0]["reality-opts"]?["public-key"]?.stringValue == "PUBKEY")
        #expect(nodes[1]["ws-opts"]?["path"]?.stringValue == "/ws")
        #expect(nodes[2]["skip-cert-verify"]?.boolValue == true)
        #expect(nodes[3]["cipher"]?.stringValue == "aes-256-gcm")
        #expect(nodes[4]["tls"]?.boolValue == true)

        let b64Bundle = Data(combined.utf8).base64EncodedString()
        #expect(ShareLinkParser.looksLikeShareLinks(b64Bundle))
        let fromB64 = try ShareLinkParser.parseBundle(b64Bundle)
        #expect(fromB64.count == 5)
    }

    @Test("SimpleYAML parses and emits Clash profiles with flow and block collections")
    func yamlRoundTrip() throws {
        let sample = """
        mixed-port: 7890
        mode: rule
        proxies:
          - name: Tokyo 01
            type: socks5
            server: 127.0.0.1
            port: 1080
          - { name: HK 02, type: ss, server: hk.example.com, port: 8388, cipher: aes-256-gcm, password: secret }
        rules:
          - DOMAIN-SUFFIX,github.com,AUTO
          - MATCH,DIRECT
        """
        let parsed = try SimpleYAML.parse(sample)
        #expect(parsed["mixed-port"]?.intValue == 7890)
        #expect(parsed["proxies"]?.arrayValue?.count == 2)
        #expect(parsed["proxies"]?.arrayValue?[1]["name"]?.stringValue == "HK 02")
        #expect(parsed["rules"]?.arrayValue?.count == 2)

        let emitted = SimpleYAML.emit(parsed)
        let reparsed = try SimpleYAML.parse(emitted)
        #expect(reparsed == parsed)
    }

    @Test("RunningAppGrouper collapses nested macOS Helper.app binaries into the main app")
    func appBundleGrouping() {
        let processes = [
            RunningProcess(pid: 100, name: "Google Chrome", executable: "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            RunningProcess(pid: 101, name: "Google Chrome Helper", executable: "Google Chrome Helper", path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            RunningProcess(pid: 200, name: "curl", executable: "curl", path: "/usr/bin/curl"),
        ]
        let grouped = RunningAppGrouper.group(processes)
        #expect(grouped.count == 2)
        let chrome = grouped.first { $0.name == "Google Chrome" }
        #expect(chrome?.instanceCount == 2)
        #expect(chrome?.primaryPath == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    }

    @Test("ConnectionLogParser handles route matches, failures, and hides internal speedtest probe")
    func connectionLogParsing() {
        let ok = ConnectionLogParser.parse(
            time: "11:00:00",
            message: "[TCP] 127.0.0.1:1234(Chrome) --> example.com:443 match Domain(example.com) using Group[Node]"
        )
        #expect(ok?.app == "Chrome")
        #expect(ok?.exit == "Group[Node]")
        #expect(ok?.decision == "Domain(example.com)")
        #expect(ok?.failed == false)

        let fail = ConnectionLogParser.parse(
            time: "11:00:01",
            message: "[TCP] dial Work Group (match Domain/example.com) 127.0.0.1:1234(App) --> example.com:443 error: timeout"
        )
        #expect(fail?.exit == "Work Group")
        #expect(fail?.failed == true)
        #expect(fail?.decision == "Domain/example.com · timeout")

        let internalProbe = ConnectionLogParser.parse(
            time: "11:00:02",
            message: "[TCP] 127.0.0.1:1234(App) --> speed.cloudflare.com:443 match Match using RoutePilot.Internal.SpeedTest[JP]"
        )
        #expect(internalProbe == nil)
    }

    @Test("Remote subscription imports return the exact provider to refresh")
    func remoteImportIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(dataDirectory: directory)
        let original = try await store.addRemoteSubscription(name: "Z", urlString: "https://example.org/z")
        #expect(original.providers.count == 1)
        let first = try await store.createRemoteSubscription(name: "A", urlString: "https://example.org/one")
        let next = try await store.createRemoteSubscription(name: "A", urlString: "https://example.org/two")
        #expect(first == "A")
        #expect(next == "A 2")
        let summary = await store.summary()
        #expect(summary.providers.first { $0.name == next }?.url == "https://example.org/two")
    }

    @Test("ProfileStore manages rules, fixed SOCKS5 listeners, and runtime config synthesis")
    func profileStoreLifecycle() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xeylroute-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try ProfileStore(dataDirectory: tmp)
        let (_, added) = try await store.importShareLinks("trojan://secret@jp.example.com:443#JP")
        #expect(added == 1)

        var summary = try await store.addOrUpdateRule(
            editingLine: nil,
            conditions: RuleConditions(target: "github.com", suffix: true),
            exit: "JP"
        )
        #expect(summary.rules.contains { $0.kind == "DOMAIN-SUFFIX" && $0.payload == "github.com" && $0.exit == "JP" })

        summary = try await store.addFixedSocks(FixedSocksBinding(port: 19081, node: "JP", provider: nil))
        #expect(summary.fixedSocks.count == 1)

        let runtimeData = try await store.buildRuntimeConfig(
            controllerPort: 19090,
            secret: "tok",
            probePort: 19091,
            enableTUN: false
        )
        let runtime = try JSONValue.decode(from: runtimeData)
        let listeners = runtime["listeners"]?.arrayValue ?? []
        #expect(listeners.contains { $0["type"]?.stringValue == "socks" && $0["port"]?.intValue == 19081 && $0["proxy"]?.stringValue == "JP" })

        try await store.saveBackup()
        _ = try await store.setMode(.global)
        let restored = try await store.restoreBackup()
        #expect(restored.mode == .rule)
    }
}

extension XeylrouteCoreTests {
    #if os(macOS)
    @Test("Subprocess output larger than the pipe capacity reaches EOF")
    func drainLargeCommandOutput() throws {
        let output = try MacCommand.output("/usr/bin/head", ["-c", "524288", "/dev/zero"])
        #expect(output.status == 0)
        #expect(output.text.utf8.count == 524288)
    }
    #endif

    @Test("Subscription downloads validate HTTP, HTML, BOM and wrapped Base64")
    func downloadFormats() throws {
        let yaml = "\u{feff}proxies:\n- {name: Local, type: socks5, server: localhost, port: 1080}"
        let payload = try SubscriptionDownload.validatedPayload(Data(yaml.utf8), status: 200)
        #expect(try SimpleYAML.parse(payload)["proxies"]?.arrayValue?.first?["name"]?.stringValue == "Local")

        let link = "trojan://fixture@localhost:443#Node"
        let encoded = Data(link.utf8).base64EncodedString()
        let wrapped = encoded.prefix(16) + "\r\n" + encoded.dropFirst(16)
        let links = try SubscriptionDownload.validatedPayload(Data(wrapped.utf8), status: 200)
        #expect(try SimpleYAML.parse(links)["proxies"]?.arrayValue?.count == 1)
        for (status, body) in [(403, yaml), (200, "<html>Login</html>"), (200, "proxies: [broken]")] {
            #expect(throws: (any Error).self) {
                try SubscriptionDownload.validatedPayload(Data(body.utf8), status: status)
            }
        }
    }
}

extension XeylrouteCoreTests {
    @Test("Runtime selectors use the active source and rules resolve provider nodes")
    func selectedProviderRouting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(dataDirectory: directory)
        for name in ["First", "Second"] {
            _ = try await store.importLocalSubscriptionYAML(name: name, content: "proxies:\n- {name: Node-\(name), type: http, server: localhost, port: 9001}")
        }
        _ = try await store.setSubscriptionScope("Second")
        _ = try await store.setProgramExits(paths: ["/Applications/Demo.app/Contents/MacOS/Demo"], exit: "Node-Second")
        let data = try await store.buildRuntimeConfig(controllerPort: 19190, secret: "fixture", probePort: 19191, enableTUN: false)
        let groups = try #require(JSONValue.decode(from: data)["proxy-groups"]?.arrayValue)
        for name in ["AUTO", "GLOBAL", "Node-Second"] {
            let group = try #require(groups.first { $0["name"]?.stringValue == name })
            #expect(group["use"]?.arrayValue == [.string("Second")])
        }
    }
}
