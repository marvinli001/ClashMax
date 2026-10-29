import type { SiteContent } from './content'

/**
 * 中文文案。
 *
 * 产品文档语气：短陈述句、技术名词、书面用语。不写口语，不写解释页面自身的元
 * 说明（例如"照 app 重画""页面也写清"）。中文是独立的一份记录，不是英文的译文。
 */
export const zh: SiteContent = {
  locale: 'zh',
  htmlLang: 'zh-Hans',
  intlLocale: 'zh-CN',
  otherLocaleName: 'English',

  meta: {
    title: 'ClashMax - 原生 macOS Mihomo (Clash Meta) 客户端',
    description:
      '免费开源（GPL-3.0）的 macOS Mihomo / Clash Meta 客户端，基于 SwiftUI 构建，支持 macOS 15 及以上。提供配置与订阅管理、代理组、规则、连接、日志、系统代理与 TUN 模式。',
    siteName: 'ClashMax',
    keywords: [
      'ClashMax',
      'Mihomo 客户端',
      'Clash Meta',
      'Clash Mac 客户端',
      'macOS 代理客户端',
      'Mac 代理软件',
      'ClashX 替代',
      'Clash Verge 替代',
      'TUN 模式',
      '系统代理',
      '订阅',
      '开源',
    ],
    category: '网络代理客户端',
    featureList: [
      '导入 Clash / Mihomo YAML 配置和订阅',
      '代理组切换与延迟测试',
      '实时连接、规则和日志',
      '系统代理模式，停止后自动还原',
      '通过特权 helper 运行 TUN 模式',
      '菜单栏控制',
      '从 ClashX、Clash Verge、FlClash 迁移',
      '内置 Mihomo 内核与应用内更新',
    ],
  },

  nav: {
    skipToContent: '跳到内容',
    languageLabel: '语言',
    repo: '仓库',
    community: 'Telegram',
  },

  hero: {
    headline: '原生 macOS',
    headlineTail: 'Mihomo 客户端',
    subtext:
      '基于 SwiftUI 构建的 Mihomo 图形客户端。集成配置管理、代理组、规则、日志、系统代理与 TUN 模式，支持 macOS 15 及以上。',
    primaryCta: '下载 DMG',
    primaryCtaAria: '下载最新 ClashMax DMG',
    secondaryCta: 'GitHub',
    tertiaryCta: '提交 Issue',
    communityCta: '加入 Telegram 群组',
  },

  shot: {
    alt: 'ClashMax 首页，内核运行中：运行状态、实时流量、当前节点、公网 IP 和代理组。',
    caption: '首页，内核运行中。配置与节点为示例数据。',
  },

  strip: {
    live: '实时',
    fallback: '离线数据',
    checking: '同步中',
    appVersion: 'ClashMax 版本',
    appBuild: '构建号',
    core: 'Mihomo 内核',
    platform: '系统要求',
    platformValue: 'macOS 15+',
    platformNote: 'SwiftUI · GPL-3.0',
    released: '发布于',
    coreReleased: '上游发布于',
    releaseNotes: '发布说明',
    buildNote: '当前发布通道',
  },

  dashboard: {
    heading: '启动即进入控制台。',
    body:
      '启停内核、切换代理模式、检查 TUN 与 helper 就绪状态，系统代理异常时提供恢复操作。',
    figure: '图 1',
    caption: 'Dashboard 示意：内核运行中，系统代理已启用。',
    callouts: [
      { label: '运行控制', detail: '内核状态、当前配置与启停控制' },
      { label: '流量', detail: '内核实时采样的上下行速率' },
      { label: '路径', detail: '当前节点与接管方式：系统代理或 TUN' },
    ],
    app: {
      status: '运行中 v1.19.33',
      stop: '停止',
      pills: [
        { label: '配置', value: 'Home' },
        { label: '模式', value: '规则' },
        { label: '控制器', value: '127.0.0.1:9097' },
      ],
      proxy: { label: '代理', value: '系统代理' },
      info: [
        { label: '代理组', value: '6' },
        { label: '连接', value: '12' },
        { label: '规则', value: '214' },
        { label: '控制器', value: '127.0.0.1:9097' },
      ],
      metrics: [
        { label: '下载', value: '1.4 MB/s', foot: '实时流量', mark: 'down' },
        { label: '上传', value: '88 KB/s', foot: '实时流量', mark: 'up' },
        { label: '连接', value: '12', foot: '实时数据流', mark: 'network' },
        { label: '规则', value: '214', foot: '已加载规则', mark: 'rules' },
      ],
      node: {
        title: '当前节点',
        badge: '运行时',
        name: '自动 - 最低延迟',
        group: 'PROXY',
        type: 'Selector',
        delay: '42 ms',
        groupLabel: '代理组',
        nodeLabel: '节点',
      },
      network: {
        title: '网络状态',
        stats: [
          { label: 'API', value: 'Bearer' },
          { label: '模式', value: '规则' },
          { label: '局域网', value: '关闭' },
          { label: 'IPv6', value: '关闭' },
        ],
        lines: [
          { label: '控制器', value: '127.0.0.1:9097' },
          { label: '代理', value: '系统代理 127.0.0.1:7890' },
        ],
      },
    },
  },

  config: {
    heading: '原始配置只读，运行配置由应用托管。',
    body:
      '启动前基于原始 YAML 生成运行配置，注入端口、控制器鉴权、DNS、TUN 与运行模式。',
    sourceLabel: '配置来源',
    sourceNote: '订阅与本地 YAML 独立保存，不受启动注入影响。',
    runtimeLabel: '托管启动',
    runtimeNote: '仅写入 Mihomo 启动所需字段，原始配置保持不变。',
    injected: '托管字段',
    injectedKeys: [
      { key: 'external-controller', value: '127.0.0.1' },
      { key: 'secret', value: '每次启动生成' },
      { key: 'mixed-port', value: '应用管理' },
      { key: 'mode', value: 'rule / global / direct' },
      { key: 'dns', value: '应用覆写' },
      { key: 'tun', value: 'helper 管理' },
    ],
  },

  legend: {
    heading: '八个功能界面。',
    body: 'Dashboard、配置、代理、连接、规则、日志、设置与菜单栏。',
    entries: [
      {
        symbol: 'dashboard',
        name: 'Dashboard',
        detail: '启停内核、切换模式、检查 TUN 与 helper 状态',
      },
      {
        symbol: 'profiles',
        name: '配置',
        detail: '本地 YAML 与订阅链接的导入、更新与切换',
      },
      {
        symbol: 'proxies',
        name: '代理',
        detail: '代理组切换、延迟测试与 Provider 健康状态',
      },
      {
        symbol: 'connections',
        name: '连接',
        detail: '会话、目标地址、命中规则与上下行流量',
      },
      {
        symbol: 'rules',
        name: '规则',
        detail: '追溯每条请求直连、代理或拒绝的规则依据',
      },
      {
        symbol: 'logs',
        name: '日志',
        detail: '实时 Mihomo 日志，用于配置与网络排障',
      },
      {
        symbol: 'settings',
        name: '设置',
        detail: '端口、DNS、TUN、开机启动与更新',
      },
      {
        symbol: 'menubar',
        name: '菜单栏',
        detail: '运行状态与快捷控制',
      },
    ],
  },

  replicas: {
    heading: '代理组一览可读，连接逐条可查。',
    body:
      '节点延迟、当前选择、命中规则与出站链路。',
    tabs: [
      { id: 'proxies', label: '代理' },
      { id: 'connections', label: '连接' },
    ],
    figures: {
      proxies: {
        figure: '图 2',
        caption: '代理：Selector 组及各节点延迟。',
      },
      connections: {
        figure: '图 3',
        caption: '连接：活动连接及其命中规则。',
      },
    },
    proxies: {
      groupName: 'PROXY',
      groupType: 'Selector',
      testAll: '全部测速',
      nodes: [
        { name: '自动 - 最低延迟', delay: 42, current: true },
        { name: '东京 01', delay: 68 },
        { name: '新加坡 03', delay: 91 },
        { name: '洛杉矶 02', delay: 184 },
        { name: '法兰克福 01', delay: null },
      ],
    },
    connections: {
      columns: { host: '目标', rule: '规则', chain: '链路', upload: '上行' },
      rows: [
        { host: 'api.github.com', rule: 'DOMAIN-SUFFIX', chain: 'PROXY', up: '12.4 KB', clearance: 'proxy' },
        { host: 'time.apple.com', rule: 'DOMAIN-SUFFIX', chain: 'DIRECT', up: '380 B', clearance: 'direct' },
        { host: 'ads.doubleclick.net', rule: 'DOMAIN-SUFFIX', chain: 'REJECT', up: '0 B', clearance: 'reject' },
        { host: '192.168.1.14', rule: 'IP-CIDR', chain: 'DIRECT', up: '2.1 KB', clearance: 'direct' },
      ],
      totals: '4 条活动连接',
    },
  },

  restricted: {
    heading: '明确的安全边界。',
    body: '涉及本机网络的每项操作均在既定约束内执行。',
    boundaries: [
      {
        title: '本地控制面',
        detail: 'Mihomo 控制器绑定 127.0.0.1，并启用 Bearer 鉴权。',
      },
      {
        title: '每次启动密钥',
        detail: '每次启动生成新的控制器密钥，不使用静态凭据。',
      },
      {
        title: 'Helper 边界',
        detail:
          '系统代理由用户态进程管理；TUN 由特权 helper 管理，并校验内核与配置路径。',
      },
      {
        title: '仅运行内置内核',
        detail: '仅运行应用内置的 Mihomo 内核。新增内核通道须具备清单、哈希校验与 helper 白名单。',
      },
      {
        title: '钥匙串凭据',
        detail: '订阅链接按配置 ID 存储于钥匙串，不写入运行配置。',
      },
      {
        title: 'GPL-3.0 许可',
        detail: '分发并控制 Mihomo，遵循 GPL-3.0 兼容许可。',
      },
    ],
  },

  approach: {
    heading: '四步完成安装。',
    body: '从下载到内核运行。',
    steps: [
      { title: '下载 DMG', detail: '从最新 Release 获取 ClashMax-X.Y.Z.dmg。' },
      {
        title: '移入应用程序',
        detail: '须安装至 /Applications，helper 授权与实验性 Network Extension 依赖此路径。',
      },
      {
        title: '导入配置',
        detail: '导入本地 Clash / Mihomo YAML 或订阅链接，在 Dashboard 启动内核。',
      },
      {
        title: '授予系统权限',
        detail: 'TUN 模式与 NE Proxy 需分别获得 macOS 授权；系统代理模式无需授权。',
      },
    ],
  },

  faq: {
    heading: '常见问题。',
    body: '功能、兼容性、迁移与更新。',
    items: [
      {
        question: 'ClashMax 是什么？',
        answer:
          'ClashMax 是 Mihomo（Clash Meta）内核的免费图形客户端，基于 SwiftUI 构建，支持 macOS 15 及以上。支持导入 Clash / Mihomo YAML 配置与订阅，内置 Mihomo 内核，提供代理组、连接、规则、日志、系统代理、TUN 模式与菜单栏控制。',
      },
      {
        question: 'ClashMax 是否免费、开源？',
        answer:
          '免费，基于 GPL-3.0 协议开源。源码、版本与 Issue 均公开于 GitHub。无需账号，不收集遥测数据。',
      },
      {
        question: '支持哪些 Mac？',
        answer:
          'macOS 15 及以上，支持 Apple Silicon 与 Intel。每个版本内置对应的稳定版 Mihomo 内核，无需单独安装或更新。',
      },
      {
        question: '能否从 ClashX、Clash Verge 或 FlClash 迁移？',
        answer:
          '支持。在配置页选择“添加”>“从其他客户端导入”，指定对应客户端的配置目录。ClashMax 读取其中的配置与订阅并生成迁移报告，确认后写入。Clash / Mihomo YAML 文件与订阅链接可直接导入。',
      },
      {
        question: 'ClashMax 与 Clash Verge Rev、Clash Party 有何区别？',
        answer:
          'Clash Verge Rev 与 Clash Party 是基于 Web 技术（Tauri、Electron）的跨平台客户端。ClashMax 是仅面向 macOS 的原生 SwiftUI 应用，侧重内核行为的可追溯性：域名命中的规则、流量未经代理的原因，以及变更生效前生成的运行配置。',
      },
      {
        question: 'ClashMax 是否修改原始配置？',
        answer:
          '不修改。导入的 YAML 保持原样。每次启动前，ClashMax 另行生成运行配置，注入端口、本地控制器、单次启动密钥、DNS、TUN 与运行模式。',
      },
      {
        question: '系统代理与 TUN 模式有何区别？',
        answer:
          '系统代理设置 macOS 的 HTTP、HTTPS 与 SOCKS 代理，仅对遵循系统代理的应用生效，无需额外授权，内核停止后自动还原。TUN 模式经特权 helper 接管全部流量，包括不遵循系统代理的应用，首次使用需在 macOS 中授权。',
      },
      {
        question: 'ClashMax 如何更新？',
        answer:
          '应用通过 Sparkle 自动检查并安装更新，版本发布于 GitHub Releases。首次安装使用 Release 页面提供的 DMG。',
      },
    ],
  },

  close: {
    heading: '开源，持续迭代。',
    body:
      '基于 GPL-3.0 兼容许可分发。缺陷报告请提交至 GitHub Issues；使用交流与版本动态见 Telegram 群组。',
    cta: '下载 DMG',
    alt: '提交 Issue',
    community: '加入 Telegram 群组',
  },

  footer: {
    license: 'GPL-3.0',
    licenseLink: '许可证',
    source: '源码',
    issues: 'Issues',
    discussions: '讨论区',
    community: 'Telegram 群组',
    security: '安全策略',
    core: 'Mihomo 内核',
    note: '原生 macOS Mihomo 客户端。',
    otherLocale: 'English',
  },
}
