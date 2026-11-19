# RoutePilot 桌面开发

当前实现为 Windows x64 桌面验证版。首次启动保持系统代理关闭。桌面端从 Windows 读取进程路径、PID、启动时间、本机 IP 与 DNS，从 Mihomo 读取节点、分组、规则、订阅、活动连接和流量统计。没有连接内核时显示空状态。独立 HTML 继续作为交互原型使用。

Mihomo 管理接口使用动态回环端口和随机认证令牌。桌面端支持规则、全局和直连模式，节点延迟、下载测速以及网站响应检测。下载测速经独立的本机代理入口下载 1 MB 样本，结果随线路和测速服务器变化。出口 IP 通过「网络详情」的检测按钮读取。

## 开发与验证

```powershell
npm install
npm run desktop -- dev
node --test scripts/routing.test.mjs
cargo test --manifest-path src-tauri/Cargo.toml
```

`npm run build` 会生成桌面前端资源。本地开发使用 `npm run desktop -- dev`。修改界面时以现有 HTML 为源，`index.html` 和 `src/prototype.js` 由构建脚本生成。

## 桌面配置

- 在「订阅导入」粘贴 HTTPS 订阅或节点分享链接，也可以导入包含节点的 Clash YAML、逐行分享链接或 Base64 文件。添加后启动本机监听以加载节点，Windows 系统代理和 TUN 由首页的开关控制。
- 分流规则和分组支持在内核运行时编辑、启停及应用。程序规则使用 Windows 返回的完整路径，程序重启后仍可按路径匹配。移出分组会保留规则与原来的独立出口。替换整份 Mihomo JSON 或修改监听端口时需要停止内核。
- 策略组可手选、自动测速或故障切换，也可引用订阅来源。删除仍被规则或分组使用的订阅会先提示清理引用。连接记录从 Mihomo 日志流接收并保留本次会话最近 500 条路由事件。
- 主窗口以普通权限运行。开启全局 TUN 时，先显示应用确认弹窗，再由 Windows 授权 TUN 后台。关闭 TUN 会停止该后台，并恢复常规本地代理监听。严格的仅指定程序接管仍待实现。
- 「按软件」归并同一 Windows 安装包内的进程，以及可通过安装目录和文件名前缀确认的辅助程序。「按进程」逐项展示 PID 和线程数，软件行可以查看所属进程并选择要配置分流的可执行路径。

## 本机内核验证

1. 从 [Mihomo v1.19.34 官方发布](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34) 下载 Windows AMD64 compatible ZIP。
2. 运行 `powershell -File scripts/Install-Mihomo.ps1 -Archive <ZIP 路径>`。脚本会核验发布哈希，并将内核放在当前用户的 RoutePilot 数据目录。已经存在的内核文件会保留。
3. 打开「订阅导入」→「本地导入」，选取 [本机验证配置](./scripts/mihomo-loopback-example.json)。该样例使用 DIRECT。连接外部代理需要自己的有效订阅或节点。

启动后通过本应用查看监听状态，必要时在同一目录查看 `mihomo.log`。验证入口限制为本机 HTTP、SOCKS5 或混合监听。端口产生冲突时会提示。需要真实接管时，内核启动后点击「启用 Windows 代理」。状态会显示在网络详情。点击恢复、停止内核或正常退出应用时，系统代理会尝试恢复原值。内核异常退出由后台检查并恢复；应用异常退出后的恢复会在下次启动时执行。只有当前值仍与 RoutePilot 写入值一致时才恢复，以保留其他应用后续改动。

已使用官方 Mihomo v1.19.34 验证回环 HTTP 转发、认证管理接口、配置热重载、本地订阅刷新、分享链接与 Base64 解析，以及独立节点测速入口。复查可运行 `python scripts/smoke-mihomo.py <ZIP 路径>`。测试使用随机回环端口。前端验证构建复用了本机已有的 Vite 7.3.6。

本地开发交付的验收缺口包括 Windows 系统代理和全局 TUN 的实机切换、真实外部订阅和代理线路的测速。严格的指定程序 TUN 和仅当前 PID 实例规则仍待实现。
