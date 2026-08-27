import type { SiteContent } from './content'

/**
 * English copy.
 *
 * The voice is the incumbent page's own: flat declarative sentences, technical
 * nouns, no metaphor. Every heading, boundary, and surface description below is
 * either lifted verbatim from docs/index.html or written to sit beside those
 * lines without a seam. The chart is the visual world; it does not get to talk.
 */
export const en: SiteContent = {
  locale: 'en',
  htmlLang: 'en',
  intlLocale: 'en',
  otherLocaleName: '简体中文',

  meta: {
    title: 'ClashMax - Native macOS Mihomo Client',
    description:
      'ClashMax is a native macOS Mihomo proxy client with profiles, proxy groups, rules, logs, system proxy, and TUN controls.',
    siteName: 'ClashMax',
  },

  nav: {
    skipToContent: 'Skip to content',
    languageLabel: 'Language',
    repo: 'Repository',
  },

  hero: {
    headline: 'macOS control',
    headlineTail: 'for Mihomo.',
    subtext:
      'A native client for the Mihomo core. Profiles, proxy groups, rules, logs, system proxy, and TUN controls, on macOS 15 and later.',
    primaryCta: 'Download DMG',
    primaryCtaAria: 'Download the latest ClashMax DMG',
    secondaryCta: 'GitHub',
    tertiaryCta: 'Open Issue',
  },

  plate: {
    label: 'Rule path preview: pick a destination to see which rule decides it',
    pick: 'Pick a destination',
    origin: '127.0.0.1',
    matched: 'Matched rule',
    clearanceNames: { proxy: 'PROXY', direct: 'DIRECT', reject: 'REJECT' },
    caption:
      'Rules are evaluated in order, top to bottom, and the first match decides the path. This is a conventional rule set; your own profile will differ.',
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
        note: 'Three rules pass, the fourth matches. Out through the selected node in the PROXY group.',
      },
      {
        host: 'time.apple.com',
        ruleIndex: 2,
        clearance: 'direct',
        note: 'Matched before the proxy rules, so it skips the tunnel and uses the physical interface.',
      },
      {
        host: '192.168.1.1',
        ruleIndex: 0,
        clearance: 'direct',
        note: 'Private address space, decided by the first rule and kept off the tunnel.',
      },
      {
        host: 'ads.doubleclick.net',
        ruleIndex: 1,
        clearance: 'reject',
        note: 'Rejected before the connection opens.',
      },
      {
        host: 'weather.internal',
        ruleIndex: 4,
        clearance: 'proxy',
        note: 'Nothing above matches, so the final MATCH rule decides.',
      },
    ],
  },

  strip: {
    live: 'GitHub live',
    fallback: 'Local fallback',
    checking: 'Checking GitHub',
    appVersion: 'ClashMax release',
    appBuild: 'Build',
    core: 'Mihomo core',
    platform: 'Platform',
    platformValue: 'macOS 15+',
    platformNote: 'SwiftUI app, GPL-3.0 boundary',
    released: 'Published',
    coreReleased: 'Latest upstream release',
    releaseNotes: 'Release notes',
    buildNote: 'Read from the current release channel',
  },

  dashboard: {
    heading: 'The first screen is the proxy client.',
    body:
      'Start, stop, switch modes, inspect TUN and helper readiness, and recover system proxy state without guessing what the app is doing.',
    figure: 'FIG. 1',
    caption: 'The Dashboard with the core running and system proxy on, redrawn from the app.',
    callouts: [
      { label: 'Runtime', detail: 'Core status, active profile, and the run control' },
      { label: 'Traffic', detail: 'Upload and download per second, sampled from the core' },
      { label: 'Path', detail: 'The current node, and whether system proxy or TUN carries it' },
    ],
    app: {
      status: 'Running v1.19.30',
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
    heading: 'Source profiles stay untouched. Runtime config is app-managed.',
    body:
      'ClashMax keeps original YAML profiles intact, then generates runtime YAML for ports, controller auth, DNS, TUN, and launch mode.',
    sourceLabel: 'Profile source',
    sourceNote:
      'Subscriptions and local YAML remain readable, recoverable, and separate from launch-time wiring.',
    runtimeLabel: 'Managed launch',
    runtimeNote: 'The app writes the values Mihomo needs without mutating the user profile.',
    injected: 'Managed runtime values',
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
    heading: 'Eight surfaces ship in the app.',
    body: 'Dashboard, Profiles, Proxies, Connections, Rules, Logs, Settings, and the macOS menu bar.',
    entries: [
      {
        symbol: 'dashboard',
        name: 'Dashboard',
        detail: 'Start, stop, switch modes, and inspect TUN and helper readiness',
      },
      {
        symbol: 'profiles',
        name: 'Profiles',
        detail: 'Local files and subscription URLs keep clear ownership and update paths',
      },
      {
        symbol: 'proxies',
        name: 'Proxies',
        detail: 'Switch proxy groups, run latency checks, and read provider health state',
      },
      {
        symbol: 'connections',
        name: 'Connections',
        detail: 'Review sessions, destinations, matched rules, upload and download',
      },
      {
        symbol: 'rules',
        name: 'Rules',
        detail: 'Trace why traffic went direct, proxied, or rejected without opening raw config',
      },
      {
        symbol: 'logs',
        name: 'Logs',
        detail: 'Mihomo logs sit near runtime controls for config and network debugging',
      },
      {
        symbol: 'settings',
        name: 'Settings',
        detail: 'Ports, DNS, TUN, launch behaviour, and updates',
      },
      {
        symbol: 'menubar',
        name: 'Menu bar',
        detail: 'Check status and run quick controls from the macOS menu bar',
      },
    ],
  },

  replicas: {
    heading: 'Groups are quick to scan. Traffic is inspectable.',
    body:
      'Both panels are rebuilt in HTML from the app’s own layout, labels, and states, so they stay legible at any size.',
    tabs: [
      { id: 'proxies', label: 'Proxies' },
      { id: 'connections', label: 'Connections' },
    ],
    figures: {
      proxies: {
        figure: 'FIG. 2',
        caption: 'Proxies: a selector group with per-node delay, redrawn from the app.',
      },
      connections: {
        figure: 'FIG. 3',
        caption:
          'Connections: open connections with the rule that matched each one, redrawn from the app.',
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
    heading: 'Security-sensitive behavior is not vague.',
    body:
      'A proxy client touches local networking, so the page states the same boundaries the app enforces.',
    boundaries: [
      {
        title: 'Local controller',
        detail:
          'Mihomo controller access is bound to 127.0.0.1 by default and protected with Bearer auth.',
      },
      {
        title: 'Per-run secret',
        detail:
          'Each launch generates a fresh controller secret instead of relying on a shared static credential.',
      },
      {
        title: 'Helper boundary',
        detail:
          'User-mode owns normal system proxy. The privileged helper owns TUN and validates app-owned core and config paths.',
      },
      {
        title: 'Single bundled core',
        detail:
          'Only the bundled Mihomo core runs. Another core channel would need a manifest, hash checks, and helper allowlisting first.',
      },
      {
        title: 'Keychain credentials',
        detail:
          'Subscription URLs are stored per profile ID in the Keychain, never in the runtime YAML.',
      },
      {
        title: 'GPL-3.0 boundary',
        detail:
          'ClashMax distributes and controls Mihomo, so it keeps a GPL-3.0 compatible licensing boundary.',
      },
    ],
  },

  approach: {
    heading: 'Install takes four steps.',
    body: 'From the release page to a running core.',
    steps: [
      { title: 'Download the DMG', detail: 'Take ClashMax-X.Y.Z.dmg from the latest release.' },
      {
        title: 'Drag to Applications',
        detail:
          'Installing into /Applications is required for helper approval and the experimental Network Extension.',
      },
      {
        title: 'Import a profile',
        detail:
          'Open a local Clash or Mihomo YAML file, or add a subscription, then start the runtime from the Dashboard.',
      },
      {
        title: 'Approve the prompt',
        detail:
          'TUN mode and NE Proxy each need their macOS approval before they can run. System proxy mode does not.',
      },
    ],
  },

  close: {
    heading: 'Open source, early, and direct about issues.',
    body:
      'ClashMax is GPL-3.0 compatible because it distributes and controls Mihomo. Reproducible bugs belong in GitHub Issues.',
    cta: 'Download DMG',
    alt: 'Report issue',
  },

  footer: {
    license: 'GPL-3.0',
    licenseLink: 'License',
    source: 'Source',
    issues: 'Issues',
    discussions: 'Discussions',
    security: 'Security policy',
    core: 'Mihomo core',
    note: 'Native macOS Mihomo client.',
    otherLocale: '简体中文',
  },
}
