<div align="center">
  <img src="ClashMax/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="ClashMax icon">
  <h1>ClashMax</h1>
  <p>面向 macOS 的原生 Mihomo 代理客户端，聚焦配置、代理组、连接、规则、日志和系统集成。</p>
  <p>
    <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2026%2B-111111?logo=apple&logoColor=white">
    <img alt="Swift" src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white">
    <img alt="Mihomo" src="https://img.shields.io/badge/core-Mihomo%20v1.19.24-2f6fed">
    <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0--compatible-2563eb">
  </p>
</div>

## 简介

ClashMax 是一个使用 SwiftUI 构建的原生 macOS Mihomo 图形客户端。它的目标不是做跨平台外壳，而是做一个符合 macOS 使用习惯的代理控制台：导入配置、启动核心、切换代理组、查看连接和规则、跟踪日志，并在系统代理模式和 TUN 模式之间切换。

项目当前处于 MVP 开发阶段。README 里的能力说明以当前代码和 MVP 目标为准，未把尚未验证的发布能力包装成已完成能力。

## 功能

- 原生 SwiftUI 应用壳，包含 Dashboard、Profiles、Proxies、Connections、Rules、Logs、Settings 和菜单栏控制。
- 支持导入本地 Clash/Mihomo YAML 配置。
- 支持添加、更新、重命名、删除订阅配置。
- 原始 YAML 保持不变，启动前由 ClashMax 生成应用托管的 runtime YAML。
- 运行时覆盖 `mixed-port`、`external-controller`、`secret`、`mode`、`log-level`、DNS 和 TUN。
- Mihomo controller 默认绑定到 `127.0.0.1`，每次运行生成新的 secret，并使用 Bearer 认证。
- 用户态核心负责普通系统代理模式。
- 通过 macOS `networksetup` 设置和恢复 HTTP、HTTPS、SOCKS 代理与 bypass domains。
- 通过 `SMAppService` 和 `ClashMaxHelper` 支持 privileged TUN 路径。
- 接入 Mihomo REST 和 WebSocket 控制面，覆盖 version、configs、proxies、providers、rules、connections、traffic、logs。
- 支持代理组切换、延迟测试、provider health check、模式切换、关闭连接和 runtime restart hooks。

## 当前状态

ClashMax 可以作为开发构建运行，但还不是完整公开发行版。TUN 模式依赖 helper 注册、签名和 macOS 系统批准流程，仍需要真实机器验证。App 包更新已接入 Sparkle 框架入口，但正式发布前必须生成并配置真实 Sparkle EdDSA public key、完成 Developer ID 签名/公证，并发布 appcast。

## 环境要求

- macOS 26+
- Xcode 26+
- Swift 6.0, 以当前工程配置为准
- Apple Silicon 或 Intel Mac
- `Resources/Core/` 下存在 Mihomo sidecar binaries

期望的核心文件：

```text
Resources/Core/mihomo-darwin-arm64
Resources/Core/mihomo-darwin-amd64
Resources/Core/mihomo-manifest.json
```

当前 manifest 固定 Mihomo `v1.19.24`。发布前应保证 core binary 来自可信来源，并按 manifest 校验 checksum。

## 从源码构建

克隆项目后，用 Xcode 打开 `ClashMax.xcodeproj`，选择 `ClashMax` scheme 构建 macOS app。

命令行测试：

```sh
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

本地构建并运行：

```sh
./script/build_and_run.sh
```

TUN 模式需要 helper 被正确嵌入、签名、注册，并在系统设置中获批。普通系统代理模式由用户态 app process 负责。

## App 更新发布

ClashMax 使用 Sparkle 做 `.app` 包更新，更新源默认是：

```text
https://marvinli001.github.io/ClashMax/appcast.xml
```

首次公开发布前，先按 `docs/APP_UPDATES.md` 生成 Sparkle EdDSA key，把 public key 写入 `project.yml` 的 `SUPublicEDKey`，并妥善保存 private key。资源包更新例如 Mihomo core 更新不走 Sparkle appcast，会作为独立资源更新通道实现。

## 项目结构

```text
ClashMax/
  App/                 App 入口
  Assets.xcassets/     App icon 和资源目录
  Models/              Runtime、profile、proxy、traffic、connection 数据模型
  Services/            Mihomo API、配置生成、核心进程、系统代理、TUN helper
  Stores/              AppModel 和 ProfileStore
  Views/               SwiftUI 页面
ClashMaxHelper/        Privileged helper 入口
ClashMaxTests/         XCTest 测试
Resources/Core/        Mihomo sidecar binaries 和 checksum manifest
Config/                Entitlements 和 LaunchDaemon plist
```

## 设计方向

ClashMax 的界面方向是安静、紧凑、可操作的 macOS 工具：

- 第一屏就是代理客户端本身，而不是介绍页。
- 核心状态、当前配置、路由模式、系统代理/TUN 状态、流量和最新错误应直接可见。
- 操作视图优先使用原生列表、表格、segmented controls、toggles、menus 和 SF Symbols。
- 缺少 profile、缺少 core、core crash、helper 不可用、配置校验失败等状态必须明确可恢复。

## 安全模型

- 导入的 YAML profile 保持原样并存储在本地。
- 订阅 URL 按 profile ID 存入 Keychain。
- runtime config 写入 ClashMax 托管的 Application Support 路径。
- Mihomo controller 默认只监听 `127.0.0.1`。
- 每次启动生成新的 controller secret。
- TUN 模式由 privileged helper 负责，helper 校验 app-owned core/config paths，不使用 shell interpolation 处理 app 提供的路径。
- macOS TUN runtime config 不写入 Linux-only `auto-redirect`。

## 路线图

- 补齐正式发布所需的 license 文件和分发打包流程。
- 使用 `mihomo -t` 强化 runtime config 校验。
- 完成 signed helper approval 和 TUN 真机验证流程。
- 增加可在缺少本地 core 时 clean skip 的 Mihomo integration tests。
- 完善订阅 metadata、profile validation 和 provider update 视图。
- 继续打磨 dashboard、proxy group table、logs 和 connection 工作流。

## 许可证

ClashMax 计划保持 GPL-3.0-compatible，因为它分发或控制 Mihomo。打包和分发前请检查 `LICENSE` 与 `THIRD_PARTY_NOTICES.md`。

## 致谢

- [Mihomo](https://github.com/MetaCubeX/mihomo) 提供代理核心。
- [Yams](https://github.com/jpsim/Yams) 提供 YAML 解析和生成。
- [Pow](https://github.com/EmergeTools/Pow) 提供 SwiftUI effects。
- [Sparkle](https://github.com/sparkle-project/Sparkle) 提供 macOS app 更新框架。
