<p align="center">
  <img src="ClashMaxHeroIMG-ZHHans.png" alt="ClashMax 原生 macOS Mihomo 代理客户端" width="100%">
</p>

<div align="center">
  <h1>ClashMax</h1>
  <p><a href="README.md">English</a> | <strong>简体中文</strong></p>
  <p>面向 macOS 的原生 Mihomo 代理客户端，聚焦配置管理、运行控制、代理组、连接、规则、日志和系统集成。</p>
  <p>
    <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2026%2B-111111?logo=apple&logoColor=white">
    <img alt="Swift" src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white">
    <img alt="Mihomo" src="https://img.shields.io/badge/core-Mihomo%20v1.19.27-2f6fed">
    <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0-2563eb">
  </p>
</div>

## 简介

ClashMax 是一个使用 SwiftUI 构建的原生 macOS Mihomo 图形客户端。它不是跨平台外壳，而是围绕 macOS 工作流设计的代理控制台：导入配置、启动核心、切换代理组、查看连接和规则、跟踪日志，并在系统代理模式和 TUN 模式之间快速切换。

应用界面保持克制、紧凑、可扫描。第一屏就是实际代理控制台，常用状态和操作直接呈现，不通过营销页或冗长引导阻断使用。

## 如何使用 ClashMax

1. 打开 [最新 GitHub Release](https://github.com/marvinli001/ClashMax/releases/latest)，下载当前版本的 `ClashMax-X.Y.Z.zip`。
2. 解压 zip，得到 `ClashMax.app`。
3. 将 `ClashMax.app` 移动到系统 `/Applications` 目录。普通安装使用、helper 授权以及实验性的 Network Extension 路径都应从这个已安装位置启动。
4. 从 `/Applications` 启动 ClashMax，导入 Clash/Mihomo YAML 配置或添加订阅，然后在 Dashboard 启动运行时。
5. 如果 macOS 弹出权限提示，请按需批准 helper 或 System Extension。TUN 模式和 `NE Proxy` 都需要对应的 macOS 授权后才能运行。

## 核心能力

- 原生 macOS 应用体验，覆盖 Dashboard、Profiles、Proxies、Connections、Rules、Logs、Settings 和菜单栏控制。
- 支持导入本地 Clash/Mihomo YAML 配置，并支持订阅配置的添加、更新、重命名和删除。
- 保留原始 YAML 不变，启动前生成 ClashMax 托管的 runtime YAML，便于安全注入端口、controller、secret、DNS、TUN 和运行模式。
- 内置 Mihomo sidecar core，并在设置中呈现 App 版本、构建号和随包内置的 Mihomo 版本。
- 支持普通系统代理模式，由用户态核心负责 HTTP、HTTPS、SOCKS 代理设置与恢复。
- 支持 privileged helper 驱动的 TUN 路径，适配 macOS 的系统批准和权限模型。
- 接入 Mihomo REST 与 WebSocket 控制面，覆盖版本、配置、代理组、provider、规则、连接、流量和日志。
- 支持代理组切换、延迟测试、provider health check、模式切换、连接关闭、运行时重启和实时日志观察。
- 菜单栏提供轻量运行控制，适合日常快速查看状态、切换代理和检查更新。

## 使用场景

- 日常代理控制：选择配置，启动 Mihomo，按需切换 Rule、Global、Direct 等运行模式。
- 节点与代理组管理：查看代理组状态，手动切换节点，执行延迟测试和 provider health check。
- 连接排查：查看当前连接、目标地址、规则命中和流量变化，必要时关闭指定连接。
- 规则与日志追踪：快速检查规则列表和 runtime 日志，定位配置或网络异常。
- 系统集成：在普通系统代理和 TUN 模式之间切换，并在停止运行时恢复系统代理状态。

## 系统要求

- macOS 26+
- Apple Silicon 或 Intel Mac
- 首次使用 TUN 模式时，需要按系统提示批准 helper 权限

## 安全与隐私

- 导入的 YAML profile 保持原样并存储在本地。
- 订阅 URL 按 profile ID 存入 Keychain。
- runtime config 写入 ClashMax 托管的 Application Support 路径。
- Mihomo controller 默认只监听 `127.0.0.1`。
- 每次启动生成新的 controller secret，并使用 Bearer 认证访问控制面。
- TUN 模式由 privileged helper 负责，helper 校验 app-owned core/config paths。
- MVP core 策略保持单通道：只支持 App 自带的 bundled Mihomo core。未来如支持 core channel，必须先补 manifest、签名/哈希校验、helper allowlist、UI 状态和回滚策略。
- macOS TUN runtime config 不写入 Linux-only `auto-redirect`。

## 下载与更新

发布版通过 GitHub Releases 提供。安装后，ClashMax 可在应用内检查 App 更新；每个 App release 都包含对应的 stable Mihomo 内核，用户不需要单独安装或维护 core binary。

## 社区与反馈

- [Issues](https://github.com/marvinli001/ClashMax/issues) 用于可复现 bug、足够明确的可执行反馈，以及可以跟踪的开发任务。
- [Questions](https://github.com/marvinli001/ClashMax/discussions/new?category=questions) 用于安装、使用、配置、运行时排障等问答。
- [Ideas](https://github.com/marvinli001/ClashMax/discussions/new?category=ideas) 用于早期功能想法、产品方向和工作流提案，等想法收敛后再转成可跟踪 Issue。
- [Development](https://github.com/marvinli001/ClashMax/discussions/new?category=development) 用于较大贡献开始前的设计讨论、边界确认和验证方案对齐。
- 提交日志或截图前，请移除订阅 URL、节点凭据、私有域名和其他敏感 profile 信息。

## 本地开发

项目级开发纪律见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。本机 Agent 说明保留在 `AGENTS.md`，该文件有意不提交。

Xcode 工程由 XcodeGen 根据 `project.yml` 生成，不提交 `ClashMax.xcodeproj/`。克隆仓库后先执行：

```bash
xcodegen generate
```

然后打开生成的 `ClashMax.xcodeproj`，或直接运行：

```bash
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

## 许可证

ClashMax 使用 GPL-3.0 许可证发布。项目分发并控制 Mihomo，因此保留与 Mihomo 生态兼容的开源授权边界。

## 赞助

如果 ClashMax 对你有帮助，可以通过 GitHub Sponsor 按钮支持项目。赞助会帮助项目持续维护、发布版本并验证 macOS 兼容性。

## 致谢

- [Mihomo](https://github.com/MetaCubeX/mihomo) 提供代理核心。
- [Yams](https://github.com/jpsim/Yams) 提供 YAML 解析和生成。
- [Pow](https://github.com/EmergeTools/Pow) 提供 SwiftUI effects。
- [SwiftUI-Shimmer](https://github.com/markiv/SwiftUI-Shimmer) 提供加载骨架屏 shimmer 效果。
- [Sparkle](https://github.com/sparkle-project/Sparkle) 提供 macOS app 更新框架。
