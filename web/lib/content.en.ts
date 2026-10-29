import type { SiteContent } from './content'

/**
 * English copy.
 *
 * Product-documentation voice: short declarative sentences, technical nouns,
 * no casual phrasing, and no meta commentary about the page itself (no
 * "redrawn from the app", no "the page states"). The chart does not get to talk.
 */
export const en: SiteContent = {
  locale: 'en',
  htmlLang: 'en',
  intlLocale: 'en',
  otherLocaleName: '简体中文',

  meta: {
    title: 'ClashMax - Native Mihomo (Clash Meta) Client for macOS',
    description:
      'Free, open-source (GPL-3.0) Mihomo / Clash Meta client for macOS 15 and later, built in SwiftUI. Profiles, subscriptions, proxy groups, rules, connections, logs, system proxy, and TUN mode.',
    siteName: 'ClashMax',
    keywords: [
      'ClashMax',
      'Mihomo client',
      'Mihomo GUI',
      'Clash Meta',
      'Clash for Mac',
      'macOS proxy client',
      'ClashX alternative',
      'Clash Verge alternative',
      'TUN mode',
      'system proxy',
      'SwiftUI',
      'open source',
    ],
    category: 'Network proxy client',
    featureList: [
      'Import Clash and Mihomo YAML profiles and subscriptions',
      'Proxy group switching and delay tests',
      'Live connections, rules, and logs',
      'System proxy mode with automatic restore',
      'TUN mode through a privileged helper',
      'Menu bar controls',
      'Migration from ClashX, Clash Verge, and FlClash',
      'Bundled Mihomo core with in-app updates',
    ],
  },

  nav: {
    skipToContent: 'Skip to content',
    languageLabel: 'Language',
    repo: 'Repository',
    community: 'Telegram',
  },

  hero: {
    headline: 'macOS control',
    headlineTail: 'for Mihomo.',
    subtext:
      'A native SwiftUI client for the Mihomo core. Profiles, proxy groups, rules, logs, system proxy, and TUN mode on macOS 15 and later.',
    primaryCta: 'Download DMG',
    primaryCtaAria: 'Download the latest ClashMax DMG',
    secondaryCta: 'GitHub',
    tertiaryCta: 'Report an Issue',
    communityCta: 'Join Telegram',
  },

  shot: {
    alt: 'The ClashMax Home page while the core runs: status, live traffic, current node, public IP, and proxy groups.',
    caption: 'Home, core running. Sample profile and nodes.',
  },

  strip: {
    live: 'Live',
    fallback: 'Offline data',
    checking: 'Syncing',
    appVersion: 'ClashMax version',
    appBuild: 'Build',
    core: 'Mihomo core',
    platform: 'Requires',
    platformValue: 'macOS 15+',
    platformNote: 'SwiftUI · GPL-3.0',
    released: 'Released',
    coreReleased: 'Upstream release',
    releaseNotes: 'Release notes',
    buildNote: 'Current release channel',
  },

  dashboard: {
    heading: 'The first screen is the console.',
    body:
      'Start and stop the core, switch modes, check TUN and helper readiness, and recover system proxy state.',
    figure: 'FIG. 1',
    caption: 'Dashboard schematic: core running, system proxy on.',
    callouts: [
      { label: 'Runtime', detail: 'Core status, active profile, and run control' },
      { label: 'Traffic', detail: 'Upload and download rates sampled from the core' },
      { label: 'Path', detail: 'Current node and active path: system proxy or TUN' },
    ],
    app: {
      status: 'Running v1.19.33',
      stop: 'Stop',
      pills: [
        { label: 'Profile', value: 'Home' },
        { label: 'Mode', value: 'Rule' },
        { label: 'Controller', value: '127.0.0.1:9097' },
      ],
      proxy: { label: 'Proxy', value: 'System Proxy' },
      info: [
        { label: 'Groups', value: '6' },
        { label: 'Connections', value: '12' },
        { label: 'Rules', value: '214' },
        { label: 'Controller', value: '127.0.0.1:9097' },
      ],
      metrics: [
        { label: 'Download', value: '1.4 MB/s', foot: 'Live traffic', mark: 'down' },
        { label: 'Upload', value: '88 KB/s', foot: 'Live traffic', mark: 'up' },
        { label: 'Connections', value: '12', foot: 'Live stream', mark: 'network' },
        { label: 'Rules', value: '214', foot: 'Loaded rules', mark: 'rules' },
      ],
      node: {
        title: 'Current Node',
        badge: 'Runtime',
        name: 'Auto - Lowest delay',
        group: 'PROXY',
        type: 'Selector',
        delay: '42 ms',
        groupLabel: 'Group',
        nodeLabel: 'Node',
      },
      network: {
        title: 'Network Status',
        stats: [
          { label: 'API', value: 'Bearer' },
          { label: 'Mode', value: 'Rule' },
          { label: 'LAN', value: 'Off' },
          { label: 'IPv6', value: 'Off' },
        ],
        lines: [
          { label: 'Controller', value: '127.0.0.1:9097' },
          { label: 'Proxy', value: 'System Proxy 127.0.0.1:7890' },
        ],
      },
    },
  },

  config: {
    heading: 'Source profiles stay read-only. Runtime config is app-managed.',
    body:
      'Before launch, ClashMax derives runtime YAML from the source profile and injects ports, controller auth, DNS, TUN, and run mode.',
    sourceLabel: 'Profile source',
    sourceNote:
      'Subscriptions and local YAML are stored apart from launch-time values.',
    runtimeLabel: 'Managed launch',
    runtimeNote: 'Only the fields Mihomo needs at launch are written. The source profile is never modified.',
    injected: 'Managed fields',
    injectedKeys: [
      { key: 'external-controller', value: '127.0.0.1' },
      { key: 'secret', value: 'generated per run' },
      { key: 'mixed-port', value: 'app-managed' },
      { key: 'mode', value: 'rule / global / direct' },
      { key: 'dns', value: 'app-managed override' },
      { key: 'tun', value: 'helper-owned' },
    ],
  },

  legend: {
    heading: 'Eight surfaces.',
    body: 'Dashboard, Profiles, Proxies, Connections, Rules, Logs, Settings, and the menu bar.',
    entries: [
      {
        symbol: 'dashboard',
        name: 'Dashboard',
        detail: 'Start, stop, switch modes, check TUN and helper readiness',
      },
      {
        symbol: 'profiles',
        name: 'Profiles',
        detail: 'Import, update, and switch local YAML and subscriptions',
      },
      {
        symbol: 'proxies',
        name: 'Proxies',
        detail: 'Proxy group selection, latency tests, provider health',
      },
      {
        symbol: 'connections',
        name: 'Connections',
        detail: 'Sessions, destinations, matched rules, traffic',
      },
      {
        symbol: 'rules',
        name: 'Rules',
        detail: 'The rule behind every direct, proxied, or rejected request',
      },
      {
        symbol: 'logs',
        name: 'Logs',
        detail: 'Live Mihomo logs for config and network diagnosis',
      },
      {
        symbol: 'settings',
        name: 'Settings',
        detail: 'Ports, DNS, TUN, launch at login, updates',
      },
      {
        symbol: 'menubar',
        name: 'Menu bar',
        detail: 'Status and quick controls',
      },
    ],
  },

  replicas: {
    heading: 'Groups at a glance. Traffic, line by line.',
    body:
      'Node latency, current selection, matched rules, and outbound chains.',
    tabs: [
      { id: 'proxies', label: 'Proxies' },
      { id: 'connections', label: 'Connections' },
    ],
    figures: {
      proxies: {
        figure: 'FIG. 2',
        caption: 'Proxies: a selector group with per-node latency.',
      },
      connections: {
        figure: 'FIG. 3',
        caption: 'Connections: open connections and their matched rules.',
      },
    },
    proxies: {
      groupName: 'PROXY',
      groupType: 'Selector',
      testAll: 'Test all',
      nodes: [
        { name: 'Auto - Lowest delay', delay: 42, current: true },
        { name: 'Tokyo 01', delay: 68 },
        { name: 'Singapore 03', delay: 91 },
        { name: 'Los Angeles 02', delay: 184 },
        { name: 'Frankfurt 01', delay: null },
      ],
    },
    connections: {
      columns: { host: 'Host', rule: 'Rule', chain: 'Chain', upload: 'Up' },
      rows: [
        { host: 'api.github.com', rule: 'DOMAIN-SUFFIX', chain: 'PROXY', up: '12.4 KB', clearance: 'proxy' },
        { host: 'time.apple.com', rule: 'DOMAIN-SUFFIX', chain: 'DIRECT', up: '380 B', clearance: 'direct' },
        { host: 'ads.doubleclick.net', rule: 'DOMAIN-SUFFIX', chain: 'REJECT', up: '0 B', clearance: 'reject' },
        { host: '192.168.1.14', rule: 'IP-CIDR', chain: 'DIRECT', up: '2.1 KB', clearance: 'direct' },
      ],
      totals: '4 open connections',
    },
  },

  restricted: {
    heading: 'Explicit security boundaries.',
    body:
      'Every operation that touches local networking runs within a defined constraint.',
    boundaries: [
      {
        title: 'Local controller',
        detail:
          'The Mihomo controller binds to 127.0.0.1 and requires Bearer auth.',
      },
      {
        title: 'Per-run secret',
        detail:
          'Each launch generates a new controller secret. No static credentials.',
      },
      {
        title: 'Helper boundary',
        detail:
          'User mode manages the system proxy. A privileged helper manages TUN and validates core and config paths.',
      },
      {
        title: 'Single bundled core',
        detail:
          'Only the bundled Mihomo core runs. Any additional core channel requires a manifest, hash verification, and helper allowlisting.',
      },
      {
        title: 'Keychain credentials',
        detail:
          'Subscription URLs are stored in the Keychain by profile ID and never written to runtime YAML.',
      },
      {
        title: 'GPL-3.0 license',
        detail:
          'ClashMax distributes and controls Mihomo under a GPL-3.0 compatible license.',
      },
    ],
  },

  approach: {
    heading: 'Install in four steps.',
    body: 'From download to a running core.',
    steps: [
      { title: 'Download the DMG', detail: 'Get ClashMax-X.Y.Z.dmg from the latest release.' },
      {
        title: 'Move to Applications',
        detail:
          'Required for helper approval and the experimental Network Extension.',
      },
      {
        title: 'Import a profile',
        detail:
          'Import a local Clash or Mihomo YAML file or a subscription URL, then start the core from the Dashboard.',
      },
      {
        title: 'Grant permissions',
        detail:
          'TUN mode and NE Proxy each require macOS approval. System proxy mode does not.',
      },
    ],
  },

  faq: {
    heading: 'FAQ.',
    body: 'Features, compatibility, migration, and updates.',
    items: [
      {
        question: 'What is ClashMax?',
        answer:
          'ClashMax is a free graphical client for the Mihomo (Clash Meta) core, built in SwiftUI for macOS 15 and later. It imports Clash and Mihomo YAML profiles and subscriptions, runs a bundled Mihomo core, and provides proxy groups, connections, rules, logs, system proxy, TUN mode, and menu bar controls.',
      },
      {
        question: 'Is ClashMax free and open source?',
        answer:
          'Yes. ClashMax is free and licensed under GPL-3.0. Source, releases, and issues are public on GitHub. No account. No telemetry.',
      },
      {
        question: 'Which Macs does it run on?',
        answer:
          'macOS 15 or later, on Apple Silicon and Intel. Each release bundles the matching stable Mihomo core; no separate core installation is required.',
      },
      {
        question: 'Can profiles be migrated from ClashX, Clash Verge, or FlClash?',
        answer:
          'Yes. In Profiles, choose Add > Import from Other Client and select that client\'s config folder. ClashMax reads its profiles and subscriptions and presents a migration report before applying changes. Clash and Mihomo YAML files and subscription URLs import directly.',
      },
      {
        question: 'How is ClashMax different from Clash Verge Rev or Clash Party?',
        answer:
          'Clash Verge Rev and Clash Party are cross-platform clients built on web technology (Tauri and Electron). ClashMax is a native SwiftUI app for macOS only, focused on traceable core behavior: the rule a host matches, why traffic bypasses the proxy, and the runtime YAML a change produces before it is applied.',
      },
      {
        question: 'Does ClashMax modify the original profile?',
        answer:
          'No. Imported YAML stays unchanged. Before each launch, ClashMax writes a separate runtime YAML with ports, the local controller, a per-launch secret, DNS, TUN, and run mode.',
      },
      {
        question: 'How do system proxy and TUN mode differ?',
        answer:
          'System proxy sets the macOS HTTP, HTTPS, and SOCKS proxy for apps that honor it, requires no additional approval, and is restored when the core stops. TUN mode routes all traffic, including apps that ignore the system proxy, through a privileged helper that requires one-time macOS approval.',
      },
      {
        question: 'How does ClashMax update?',
        answer:
          'The app checks for and installs updates through Sparkle; releases are published on GitHub Releases. First installs use the DMG from the release page.',
      },
    ],
  },

  close: {
    heading: 'Open source. Actively developed.',
    body:
      'Distributed under a GPL-3.0 compatible license. File reproducible bugs in GitHub Issues; setup questions and release news are in the Telegram group.',
    cta: 'Download DMG',
    alt: 'Report an issue',
    community: 'Join Telegram',
  },

  footer: {
    license: 'GPL-3.0',
    licenseLink: 'License',
    source: 'Source',
    issues: 'Issues',
    discussions: 'Discussions',
    community: 'Telegram group',
    security: 'Security policy',
    core: 'Mihomo core',
    note: 'Native macOS Mihomo client.',
    otherLocale: '简体中文',
  },
}
