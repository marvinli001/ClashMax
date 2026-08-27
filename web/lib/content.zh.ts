import type { SiteContent } from './content'

/**
 * 中文文案。
 *
 * 与英文一样，语气取自旧站 docs/index.html 自己的 translations.zh：陈述句、技术
 * 名词、不用比喻。能对上的整句直接沿用旧站原文，新增的句子按同一套语气写，保证
 * 两边读起来是同一个人写的。中文是独立的一份记录，不是英文的译文。
 */
export const zh: SiteContent = {
  locale: 'zh',
  htmlLang: 'zh-Hans',
  intlLocale: 'zh-CN',
  otherLocaleName: 'English',

  meta: {
    title: 'ClashMax - 原生 macOS Mihomo 客户端',
    description:
      'ClashMax 是原生 macOS Mihomo 代理客户端，提供配置、代理组、规则、日志、系统代理和 TUN 控制。',
    siteName: 'ClashMax',
  },

  nav: {
    skipToContent: '跳到内容',
    languageLabel: '语言',
    repo: '仓库',
  },

  hero: {
    headline: '原生 macOS',
    headlineTail: '控制 Mihomo',
    subtext:
      'Mihomo 内核的原生客户端。配置、代理组、规则、日志、系统代理和 TUN 控制，支持 macOS 15 及以上。',
    primaryCta: '下载 DMG',
    primaryCtaAria: '下载最新 ClashMax DMG',
    secondaryCta: 'GitHub',
    tertiaryCta: '提交 Issue',
  },

  plate: {
    label: '规则路径预览：选一个目标地址，看哪条规则决定它',
    pick: '选一个目标地址',
    origin: '127.0.0.1',
    matched: '命中规则',
    clearanceNames: { proxy: 'PROXY', direct: 'DIRECT', reject: 'REJECT' },
    caption:
      '规则自上而下依次判定，第一条命中的决定去向。这里描的是一份常见规则集，你自己的配置会不一样。',
    ruleSet: [
      { short: '192.168/16', full: 'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve' },
      { short: 'doubleclick', full: 'DOMAIN-SUFFIX,doubleclick.net,REJECT' },
      { short: 'apple.com', full: 'DOMAIN-SUFFIX,apple.com,DIRECT' },
      { short: 'github.com', full: 'DOMAIN-SUFFIX,github.com,PROXY' },
      { short: 'MATCH', full: 'MATCH,PROXY' },
    ],
    destinations: [
      {
        host: 'github.com',
        ruleIndex: 3,
        clearance: 'proxy',
        note: '前三条都没命中，第四条命中。从 PROXY 组当前选中的节点出去。',
      },
      {
        host: 'time.apple.com',
        ruleIndex: 2,
        clearance: 'direct',
        note: '在代理规则之前就命中，绕开隧道，走物理网卡。',
      },
      {
        host: '192.168.1.1',
        ruleIndex: 0,
        clearance: 'direct',
        note: '内网地址段，第一条规则就判完，不进隧道。',
      },
      {
        host: 'ads.doubleclick.net',
        ruleIndex: 1,
        clearance: 'reject',
        note: '连接建立之前就被拒绝。',
      },
      {
        host: 'weather.internal',
        ruleIndex: 4,
        clearance: 'proxy',
        note: '上面都没命中，交给最后的 MATCH 兜底。',
      },
    ],
  },

  strip: {
    live: 'GitHub 实时',
    fallback: '本地 fallback',
    checking: '正在检查 GitHub',
    appVersion: 'ClashMax 发布',
    appBuild: '构建号',
    core: 'Mihomo 内核',
    platform: '平台',
    platformValue: 'macOS 15+',
    platformNote: 'SwiftUI app, GPL-3.0 边界',
    released: '发布时间',
    coreReleased: '最新上游 release',
    releaseNotes: '发布说明',
    buildNote: '来自当前 release channel',
  },

  dashboard: {
    heading: '第一屏就是代理客户端。',
    body:
      '启动、停止、切换模式、检查 TUN/helper ready 状态，并在系统代理异常时给出恢复路径。',
    figure: '图 1',
    caption: '内核运行中、系统代理已开启的 Dashboard，照 app 重画。',
    callouts: [
      { label: '运行控制', detail: '内核状态、当前配置，以及启停控制' },
      { label: '流量', detail: '来自内核采样的每秒上下行' },
      { label: '路径', detail: '当前节点，以及走系统代理还是 TUN' },
    ],
    app: {
      status: '运行中 v1.19.30',
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
    heading: '原始 profile 保持不动，运行态配置由应用托管。',
    body:
      'ClashMax 保留原始 YAML，在启动前生成 runtime YAML，用来写入端口、controller auth、DNS、TUN 和运行模式。',
    sourceLabel: '配置来源',
    sourceNote: '订阅和本地 YAML 保持可读、可恢复，并与启动时注入的配置分开。',
    runtimeLabel: '托管启动',
    runtimeNote: '应用只写 Mihomo 启动需要的值，不改写用户 profile。',
    injected: '托管运行态值',
    injectedKeys: [
      { key: 'external-controller', value: '127.0.0.1' },
      { key: 'secret', value: '每次启动生成' },
      { key: 'mixed-port', value: '由 app 管理' },
      { key: 'mode', value: 'rule / global / direct' },
      { key: 'dns', value: 'app 覆写' },
      { key: 'tun', value: '由 helper 持有' },
    ],
  },

  legend: {
    heading: 'app 里有八个界面。',
    body: 'Dashboard、配置、代理、连接、规则、日志、设置，以及 macOS 菜单栏。',
    entries: [
      {
        symbol: 'dashboard',
        name: 'Dashboard',
        detail: '启动、停止、切换模式，检查 TUN/helper ready 状态',
      },
      {
        symbol: 'profiles',
        name: '配置',
        detail: '本地文件和订阅 URL 有清晰归属，也有明确更新路径',
      },
      {
        symbol: 'proxies',
        name: '代理',
        detail: '切换代理组、执行延迟测试，读取 provider 健康状态',
      },
      {
        symbol: 'connections',
        name: '连接',
        detail: '查看会话、目标地址、规则命中、上传与下载',
      },
      {
        symbol: 'rules',
        name: '规则',
        detail: '看清流量为什么直连、代理或拒绝，不必先打开原始配置',
      },
      {
        symbol: 'logs',
        name: '日志',
        detail: 'Mihomo 日志靠近运行控制，便于排查配置和网络问题',
      },
      {
        symbol: 'settings',
        name: '设置',
        detail: '端口、DNS、TUN、开机启动、更新',
      },
      {
        symbol: 'menubar',
        name: '菜单栏',
        detail: '从 macOS 菜单栏查看状态并执行快速控制',
      },
    ],
  },

  replicas: {
    heading: '代理组快速可扫，流量可检查。',
    body:
      '这两块是照 app 自己的布局、文案和状态用 HTML 重画的，缩放到任何尺寸都还看得清。',
    tabs: [
      { id: 'proxies', label: '代理' },
      { id: 'connections', label: '连接' },
    ],
    figures: {
      proxies: {
        figure: '图 2',
        caption: '代理页：一个 selector 组，带每个节点的延迟，照 app 重画。',
      },
      connections: {
        figure: '图 3',
        caption: '连接页：活动连接和各自命中的规则，照 app 重画。',
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
    heading: '安全敏感行为不说空话。',
    body: '代理客户端会触碰本机网络设置，所以页面也写清应用实际执行的边界。',
    boundaries: [
      {
        title: '本地控制面',
        detail: 'Mihomo controller 默认绑定 127.0.0.1，并使用 Bearer auth 保护访问。',
      },
      {
        title: '每次启动密钥',
        detail: '每次启动生成新的 controller secret，避免依赖共享静态凭据。',
      },
      {
        title: 'Helper 边界',
        detail:
          '用户态负责普通系统代理；privileged helper 负责 TUN，并校验 app-owned core/config paths。',
      },
      {
        title: '只跑内置内核',
        detail: '只运行内置的 Mihomo 内核。要开新的内核通道，得先有清单、哈希校验和 helper 白名单。',
      },
      {
        title: 'Keychain 凭据',
        detail: '订阅链接按配置 ID 存进 Keychain，不会写进运行时 YAML。',
      },
      {
        title: 'GPL-3.0 边界',
        detail: 'ClashMax 分发并控制 Mihomo，因此保持 GPL-3.0 兼容的许可边界。',
      },
    ],
  },

  approach: {
    heading: '安装分四步。',
    body: '从 release 页面到内核跑起来。',
    steps: [
      { title: '下载 DMG', detail: '从最新 release 里取 ClashMax-X.Y.Z.dmg。' },
      {
        title: '拖进 Applications',
        detail: '必须装到 /Applications，helper 授权和实验性的 Network Extension 都依赖这个位置。',
      },
      {
        title: '导入配置',
        detail: '打开本地 Clash / Mihomo YAML 文件，或添加订阅，然后在 Dashboard 启动运行时。',
      },
      {
        title: '同意系统弹窗',
        detail: 'TUN 模式和 NE Proxy 各自需要对应的 macOS 授权才能跑。系统代理模式不需要。',
      },
    ],
  },

  close: {
    heading: '开源、早期、欢迎直接挑问题。',
    body:
      'ClashMax 因为分发并控制 Mihomo，保持 GPL-3.0 兼容边界。可复现 bug 请直接发到 GitHub Issues。',
    cta: '下载 DMG',
    alt: '反馈问题',
  },

  footer: {
    license: 'GPL-3.0',
    licenseLink: '许可证',
    source: '源码',
    issues: 'Issues',
    discussions: '讨论区',
    security: '安全策略',
    core: 'Mihomo 内核',
    note: '原生 macOS Mihomo 客户端。',
    otherLocale: 'English',
  },
}
