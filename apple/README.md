# Xeylroute Apple Native (macOS + iOS)

纯 Swift 6 + SwiftUI 原生苹果双端客户端，独立存放在 `apple/` 子目录下，与现有 Tauri 桌面版共享相同功能模型与配置格式，同时采用独立的应用数据目录（`~/Library/Application Support/Xeylroute/core/`，iOS 上使用 App Group `group.app.xeylroute.apple`）避免与 Tauri 版本锁文件或代理状态冲突。

## 架构概览

- **`Packages/XeylrouteCore`**（零外部依赖纯 Swift Package，支持 macOS 14+ / iOS 17+）：
  - `Models/`：无损 `JSONValue`、配置/规则/订阅/固定 SOCKS5/运行时快照与流量模型。
  - `Engine/`：
    - `RuleConditionsEngine`：程序路径、域名/后缀、IPv4/IPv6 CIDR、端口范围及 `AND(...)` 组合规则的编译与无损反解。
    - `ShareLinkParser`：支持 `ss://`、`vmess://`、`vless://`（含 Reality）、`trojan://`、`hysteria2://`/`hy2://`、`tuic://` 与 Base64 批量导入。
    - `SimpleYAML`：零依赖 Clash/Mihomo YAML 解析与序列化（用于本地/远端订阅及内置 YAML 编辑器）。
    - `ProfileStore`：管理 `mihomo.json`、备份恢复、订阅范围、固定回环 SOCKS5 入口、Clash 片段导出及运行时配置合成。
    - `RunningAppGrouper`、`TrafficTracker`、`ProbeQueue`、`ConnectionLogParser`。
  - `Network/MihomoClient`：对接 Mihomo 动态回环控制接口（快照、节点切换、模式切换、热重载、延迟测试、1 MB 独立端口下载测速、网站连通性检测、出口 IP 查询及最近 500 条结构化路由日志流）。
  - `Platform/`：
    - `MacMihomoRuntime`（macOS）：直接驱动随包 Mihomo 二进制、`networksetup` 系统代理接管与崩溃恢复日志、提权 TUN 后台及运行中应用/进程扫描。
    - `IOSTunnelRuntime`（iOS）：对接 `NETunnelProviderManager` 与 App Group 共享配置，支持模拟器无障碍运行与真机隧道启停。
- **`App/Shared`**（macOS + iOS 共用原生 SwiftUI 界面）：
  - **macOS**：`NavigationSplitView` 原生半透明侧栏、菜单栏常驻窗口（`MenuBarExtra`）、Swift Charts 实时流量波形与活跃连接柱状图、运行中软件原生图标与进程分流、固定回环 SOCKS5 入口与 Clash 片段复制。
  - **iOS / iPadOS**：iPhone 自适应 `TabView`、iPad 自适应 `NavigationSplitView`，自动隐藏桌面专属项，突出 VPN 隧道开关与剪贴板一键导入。
- **`App/PacketTunnel`**（iOS NetworkExtension 目标）：
  - `NEPacketTunnelProvider` 隧道实现，读取 App Group 共享配置并预留 `TunnelCoreEngine` 协议，供编译后的 `MihomoCore.xcframework` / `Libbox.xcframework` 接入。

## 构建、运行与测试

### 1. 运行核心单元测试

```bash
swift test --package-path apple/Packages/XeylrouteCore
```

### 2. 生成并打开 Xcode 工程

本目录使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 维护工程描述（`apple/project.yml`）：

```bash
cd apple
xcodegen generate
open Xeylroute.xcodeproj
```

- **macOS**：选择 Scheme `XeylrouteMac` 直接运行。构建脚本会自动复用仓库中已下载的 `src-tauri/binaries/xeylroute-mihomo-aarch64-apple-darwin`（如尚未准备，请先在根目录执行 `npm run core`）。
- **iOS 模拟器**：选择 Scheme `XeylrouteiOS` 与任意 iPhone/iPad 模拟器运行。

### 3. iOS 真机接入嵌入式内核说明

iOS 禁止子进程执行外部二进制，真机转发流量需要：
1. 使用 Go / `gomobile` 将 Mihomo 或 sing-box 编译为 `MihomoCore.xcframework`（或 `Libbox.xcframework`），并在 `apple/project.yml` 中将其添加到 `XeylrouteTunnel` 目标依赖。
2. 在 `apple/App/PacketTunnel/PacketTunnelProvider.swift` 中实现 `TunnelCoreEngine` 协议并传入 `tunFD` 与共享配置路径。
3. 在 Xcode 中为 `XeylrouteiOS` 和 `XeylrouteTunnel` 配置支持 `Network Extensions (Packet Tunnel)` 与 `App Groups` 的 Apple Developer Team 签名。
