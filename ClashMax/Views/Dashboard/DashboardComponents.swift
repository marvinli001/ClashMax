import Pow
import SwiftUI

enum DashboardLayoutMetrics {
  static let runModePickerWidth: CGFloat = 214
  static let proxyRoutingModePickerWidth: CGFloat = 272
  static let launchProfileControlWidth: CGFloat = 178
  static let launchMixedPortControlWidth: CGFloat = 104
  static let launchStartButtonWidth: CGFloat = 156
  static let dashboardGridSpacing: CGFloat = 12
  static let metricTileMinimumColumnWidth: CGFloat = 118
  static let metricTileSingleRowBreakpoint: CGFloat = 680
  static let metricTileTwoColumnBreakpoint: CGFloat = 420
  static let runningPairColumnsBreakpoint: CGFloat = 700

  static func pagePadding(for width: CGFloat) -> CGFloat {
    width < 760 ? 14 : 18
  }

  static func launchVisualSideLength(
    availableWidth: CGFloat,
    availableHeight: CGFloat,
    isVisualActive: Bool = false
  ) -> CGFloat {
    let width = max(0, availableWidth)
    let height = max(0, availableHeight)
    let candidate = min(width * 0.22, height * 0.26)
    let active = min(max(candidate, 112), 220)
    if isVisualActive { return active }
    let resting = min(active * 0.55, 96)
    return max(resting, 68)
  }

  static func launchControlsMaxWidth(availableWidth: CGFloat) -> CGFloat {
    min(max(availableWidth - 32, 360), 640)
  }

  static func dashboardMaxWidth(for width: CGFloat) -> CGFloat {
    width < 900 ? .infinity : 1180
  }
}

struct RunModePicker: View {
  let selection: Binding<RunMode>

  var body: some View {
    Picker("Mode", selection: selection) {
      ForEach(RunMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize(horizontal: true, vertical: false)
  }
}

struct ProxyRoutingModePicker: View {
  let selection: Binding<ProxyRoutingMode>

  init(selection: Binding<ProxyRoutingMode>) {
    self.selection = selection
  }

  var body: some View {
    Picker("Proxy Routing", selection: selection) {
      ForEach(ProxyRoutingMode.allCases) { mode in
        Text(mode.displayName)
          .lineLimit(1)
          .tag(mode)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .help(selection.wrappedValue.displayName)
  }
}

struct ProxyRoutingSettingsButton: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var isPresented = false
  @State private var systemDraft = SystemProxySettings.default
  @State private var tunDraft = TunSettings.default
  @State private var networkExtensionDraft = NetworkExtensionRoutingSettings.default
  @State private var settingsError: String?

  var body: some View {
    Button {
      syncDrafts()
      isPresented = true
    } label: {
      Image(systemName: "gearshape")
        .frame(width: 18, height: 18)
    }
    .buttonStyle(.borderless)
    .controlSize(.regular)
    .help("Configure \(appModel.proxyRoutingMode.displayName)")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      popoverContent
        .frame(width: 480)
        .padding(18)
    }
  }

  @ViewBuilder
  private var popoverContent: some View {
    switch appModel.proxyRoutingMode {
    case .systemProxy:
      SystemProxySettingsPopover(
        settings: $systemDraft,
        isActive: appModel.systemProxyEnabled,
        serviceAddress: "\(systemDraft.normalizedProxyHost):\(appModel.overrides.mixedPort)",
        error: settingsError,
        onCancel: { isPresented = false },
        onSave: saveSystemProxySettings
      )
    case .tun:
      TunSettingsPopover(
        settings: $tunDraft,
        error: settingsError,
        onCancel: { isPresented = false },
        onReset: { tunDraft = .default },
        onSave: saveTunSettings
      )
    case .neProxy:
      NetworkExtensionSettingsPopover(
        settings: $networkExtensionDraft,
        error: settingsError,
        onCancel: { isPresented = false },
        onSave: saveNetworkExtensionRoutingSettings
      )
    }
  }

  private func syncDrafts() {
    systemDraft = appModel.systemProxySettings
    tunDraft = appModel.tunSettings
    networkExtensionDraft = appModel.networkExtensionRoutingSettings
    settingsError = nil
  }

  private func saveSystemProxySettings() {
    if let validationError = systemDraft.validationError {
      settingsError = validationError
      return
    }
    guard appModel.updateSystemProxySettings(systemDraft) else {
      settingsError = appModel.lastError
      return
    }
    isPresented = false
  }

  private func saveTunSettings() {
    if let validationError = tunDraft.validationError {
      settingsError = validationError
      return
    }
    guard appModel.updateTunSettings(tunDraft) else {
      settingsError = appModel.lastError
      return
    }
    isPresented = false
  }

  private func saveNetworkExtensionRoutingSettings() {
    if let validationError = networkExtensionDraft.validationError {
      settingsError = validationError
      return
    }
    guard appModel.updateNetworkExtensionRoutingSettings(networkExtensionDraft) else {
      settingsError = appModel.lastError
      return
    }
    isPresented = false
  }
}

private struct NetworkExtensionSettingsPopover: View {
  @EnvironmentObject private var appModel: AppModel
  @Binding var settings: NetworkExtensionRoutingSettings
  let error: String?
  let onCancel: () -> Void
  let onSave: () -> Void
  @State private var cidrDraft = ""
  @State private var dnsServerDraft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        SettingsRuntimeLine(title: "System Extension", value: appModel.networkExtensionController.statusMessage)
        SettingsRuntimeLine(title: "Transparent Proxy", value: appModel.networkExtensionController.vpnStatus.displayName)
        SettingsRuntimeLine(title: "System Proxy", value: "Off")
        SettingsRuntimeLine(title: "TUN Helper", value: "Untouched")
        SettingsRuntimeLine(title: "TCP Bridges", value: "\(diagnostics.activeTCPBridgeCount)")
        SettingsRuntimeLine(title: "UDP Bridges", value: "\(diagnostics.activeUDPBridgeCount)")
        SettingsRuntimeLine(title: "DNS Runtime", value: settings.dnsFakeIPEnabled ? "Fake IP" : "Profile")
        SettingsRuntimeLine(title: "DNS Capture", value: settings.dnsCaptureEnabled ? "127.0.0.1:\(settings.normalizedDNSListenPort)" : "Off")
        SettingsRuntimeLine(title: "System DNS", value: appModel.networkExtensionSystemDNSState.displayName)
        SettingsRuntimeLine(title: "SOCKS Failures", value: "\(diagnostics.socksHandshakeFailureCount)")
        Text(appModel.networkExtensionController.tunnelStatusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()
        .opacity(0.24)

      Toggle("Exclude LAN", isOn: $settings.excludeLAN)
        .toggleStyle(.switch)

      Toggle("Capture DNS", isOn: $settings.dnsCaptureEnabled)
        .toggleStyle(.switch)

      Toggle("Fake IP DNS", isOn: $settings.dnsFakeIPEnabled)
        .toggleStyle(.switch)
        .disabled(!settings.dnsCaptureEnabled)

      Stepper("DNS Listen \(settings.normalizedDNSListenPort)", value: $settings.dnsListenPort, in: 1...65_535)
        .disabled(!settings.dnsCaptureEnabled)

      Toggle("System DNS Override", isOn: $settings.systemDNSOverrideEnabled)
        .toggleStyle(.switch)

      EditableStringList(
        title: "System DNS Servers",
        placeholder: "114.114.114.114",
        values: $settings.systemDNSServers,
        draft: $dnsServerDraft,
        validator: NetworkExtensionRoutingSettings.isValidDNSServer,
        normalizer: NetworkExtensionRoutingSettings.normalizedDNSServers
      )
      .disabled(!settings.systemDNSOverrideEnabled)

      EditableStringList(
        title: "Custom CIDR Exclude",
        placeholder: "192.168.0.0/16",
        values: $settings.customRouteExcludeCIDRs,
        draft: $cidrDraft,
        validator: NetworkExtensionRoutingSettings.isValidCIDR,
        normalizer: NetworkExtensionRoutingSettings.normalizedCIDRs
      )

      WrappingTokenList(title: "Effective Exclude", values: settings.effectiveRouteExcludeCIDRs)

      DiagnosticEventList(title: "Recent Bypass", events: diagnostics.recentBypasses)
      DiagnosticEventList(title: "Recent Errors", events: diagnostics.recentErrors)

      if let error = appModel.networkExtensionController.recentError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      HStack(spacing: 8) {
        Button {
          appModel.installNetworkExtension()
        } label: {
          Label("Install", systemImage: "puzzlepiece")
        }
        Button {
          appModel.openNetworkExtensionSettings()
        } label: {
          Label("Approve", systemImage: "gearshape")
        }
        .help("Open System Settings > General > Login Items & Extensions > Network Extensions.")
        Button {
          appModel.refreshNetworkExtensionStatus()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        Button {
          appModel.repairNetworkExtensionDNS()
        } label: {
          Label("Repair DNS", systemImage: "wrench.and.screwdriver")
        }
        .disabled(!appModel.canRepairNetworkExtensionDNS)
        Spacer()
        Button("Cancel", action: onCancel)
        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
          .disabled(settings.validationError != nil)
      }
    }
    .onAppear {
      appModel.refreshNetworkExtensionStatus()
    }
  }

  private var diagnostics: NetworkExtensionDiagnosticsSnapshot {
    appModel.networkExtensionController.diagnostics
  }
}

private struct SettingsRuntimeLine: View {
  let title: String
  let value: String

  var body: some View {
    HStack(spacing: 12) {
      Text(LocalizedStringKey(title))
        .foregroundStyle(.secondary)
      Spacer()
      Text(localizedDashboardText(value))
        .multilineTextAlignment(.trailing)
    }
    .font(.callout)
  }
}

private struct DiagnosticEventList: View {
  let title: String
  let events: [NetworkExtensionDiagnosticEvent]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(LocalizedStringKey(title))
        .font(.caption)
        .foregroundStyle(.secondary)
      if events.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ForEach(events.suffix(3)) { event in
          Text(displayText(for: event))
            .font(.system(.caption, design: .monospaced))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private func displayText(for event: NetworkExtensionDiagnosticEvent) -> String {
    let context = [
      event.flowProtocol?.displayName,
      event.remoteEndpoint,
      event.sourceAppSigningIdentifier.map { "source=\($0)" }
    ]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    if !context.isEmpty {
      return "\(event.message) \(context)"
    }
    return event.message
  }
}

private struct SystemProxySettingsPopover: View {
  @Binding var settings: SystemProxySettings
  let isActive: Bool
  let serviceAddress: String
  let error: String?
  let onCancel: () -> Void
  let onSave: () -> Void
  @State private var bypassDraft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      popoverHeader("System Proxy Settings", systemImage: "network.badge.shield.half.filled")

      CurrentSystemProxySummary(isActive: isActive, serviceAddress: serviceAddress)

      Form {
        TextField("Proxy Host", text: $settings.proxyHost)
        Toggle("Use Default Bypass", isOn: $settings.useDefaultBypass)
        Toggle("Validate Bypass Entries", isOn: $settings.validateBypass)
        Toggle("Proxy Guard", isOn: $settings.guardEnabled)
        LabeledContent("Guard Interval") {
          CompactIntegerStepperField(
            value: $settings.guardIntervalSeconds,
            range: SystemProxySettings.minimumGuardIntervalSeconds...SystemProxySettings.maximumGuardIntervalSeconds,
            step: 5
          )
        }
        .disabled(!settings.guardEnabled)
      }

      EditableStringList(
        title: "Custom Bypass",
        placeholder: "192.168.0.0/16",
        values: $settings.customBypassDomains,
        draft: $bypassDraft,
        validator: SystemProxySettings.isValidBypassDomain
      )

      if settings.useDefaultBypass {
        WrappingTokenList(title: "Default Bypass", values: SystemProxySettings.defaultBypassDomains)
      }

      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      popoverActions(onCancel: onCancel, onSave: onSave, saveDisabled: settings.validationError != nil)
    }
  }
}

private struct TunSettingsPopover: View {
  @Binding var settings: TunSettings
  let error: String?
  let onCancel: () -> Void
  let onReset: () -> Void
  let onSave: () -> Void
  @State private var dnsDraft = ""
  @State private var routeDraft = ""
  @State private var systemDNSDraft = ""
  @State private var fakeIPFilterDraft = ""
  @State private var defaultNameserverDraft = ""
  @State private var nameserverDraft = ""
  @State private var fallbackDraft = ""
  @State private var proxyServerNameserverDraft = ""
  @State private var directNameserverDraft = ""
  @State private var policyKeyDraft = ""
  @State private var policyValueDraft = ""
  @State private var proxyPolicyKeyDraft = ""
  @State private var proxyPolicyValueDraft = ""
  @State private var hostKeyDraft = ""
  @State private var hostValueDraft = ""
  @State private var fallbackGeoSiteDraft = ""
  @State private var fallbackIPCIDRDraft = ""
  @State private var fallbackDomainDraft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        popoverHeader("TUN Settings", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
        Spacer()
        Button("Reset Defaults", action: onReset)
      }

      Form {
        Picker("TUN Stack", selection: $settings.stack) {
          ForEach(TunStack.allCases) { stack in
            Text(stack.displayName).tag(stack)
          }
        }
        .pickerStyle(.segmented)

        TextField("Device", text: $settings.device)
        Toggle("Auto Route", isOn: $settings.autoRoute)
        Toggle("Strict Route", isOn: $settings.strictRoute)
        Toggle("Auto Detect Interface", isOn: $settings.autoDetectInterface)
        LabeledContent("MTU") {
          CompactIntegerStepperField(value: $settings.mtu, range: 576...9_000, step: 10)
        }
        Toggle("Fake IP DNS", isOn: $settings.dnsFakeIPEnabled)
        TextField("Fake IP Range", text: $settings.fakeIPRange)
          .disabled(!settings.dnsFakeIPEnabled)
        Toggle("System DNS Override", isOn: $settings.systemDNSOverrideEnabled)
      }

      VStack(alignment: .leading, spacing: 6) {
        Picker("DNS Preset", selection: dnsPresetSelection) {
          ForEach(TunDNSSettings.presets) { preset in
            Text(preset.title).tag(preset.id)
          }
          Text("Custom").tag(Self.customDNSPresetID)
        }
        .pickerStyle(.menu)

        Text(dnsPresetDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      EditableStringList(
        title: "DNS Hijack",
        placeholder: "any:53",
        values: $settings.dnsHijack,
        draft: $dnsDraft,
        validator: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains(" ") },
        normalizer: TunDNSSettings.normalizedList
      )

      EditableStringList(
        title: "Route Exclude Address",
        placeholder: "192.168.0.0/16",
        values: $settings.routeExcludeAddresses,
        draft: $routeDraft,
        validator: TunSettings.isValidRouteExcludeCIDR,
        normalizer: TunSettings.normalizedRouteExcludeCIDRs
      )

      EditableStringList(
        title: "System DNS Servers",
        placeholder: "114.114.114.114",
        values: $settings.systemDNSServers,
        draft: $systemDNSDraft,
        validator: NetworkExtensionRoutingSettings.isValidDNSServer,
        normalizer: NetworkExtensionRoutingSettings.normalizedDNSServers
      )
      .disabled(!settings.systemDNSOverrideEnabled)

      DisclosureGroup("Runtime DNS Overlay") {
        VStack(alignment: .leading, spacing: 12) {
          OptionalBoolPicker(title: "Prefer HTTP/3", value: $settings.dns.preferH3)
          OptionalBoolPicker(title: "Use Hosts", value: $settings.dns.useHosts)
          OptionalBoolPicker(title: "Use System Hosts", value: $settings.dns.useSystemHosts)
          OptionalBoolPicker(title: "Respect Rules", value: $settings.dns.respectRules)

          EditableStringList(
            title: "Fake IP Filter",
            placeholder: "*.lan",
            values: $settings.dns.fakeIPFilter,
            draft: $fakeIPFilterDraft,
            validator: TunDNSSettings.isValidPattern,
            normalizer: TunDNSSettings.normalizedList
          )

          EditableStringList(
            title: "Default Nameserver",
            placeholder: "223.5.5.5",
            values: $settings.dns.defaultNameserver,
            draft: $defaultNameserverDraft,
            validator: TunDNSSettings.isValidDefaultNameserverResolver,
            normalizer: TunDNSSettings.normalizedList
          )

          EditableStringList(
            title: "Nameserver",
            placeholder: "https://dns.alidns.com/dns-query",
            values: $settings.dns.nameserver,
            draft: $nameserverDraft,
            validator: TunDNSSettings.isValidResolver,
            normalizer: TunDNSSettings.normalizedList
          )

          EditableStringList(
            title: "Fallback",
            placeholder: "https://dns.google/dns-query",
            values: $settings.dns.fallback,
            draft: $fallbackDraft,
            validator: TunDNSSettings.isValidResolver,
            normalizer: TunDNSSettings.normalizedList
          )

          EditableStringList(
            title: "Proxy Server Nameserver",
            placeholder: "119.29.29.29",
            values: $settings.dns.proxyServerNameserver,
            draft: $proxyServerNameserverDraft,
            validator: TunDNSSettings.isValidResolver,
            normalizer: TunDNSSettings.normalizedList
          )

          EditableStringList(
            title: "Direct Nameserver",
            placeholder: "223.5.5.5",
            values: $settings.dns.directNameserver,
            draft: $directNameserverDraft,
            validator: TunDNSSettings.isValidResolver,
            normalizer: TunDNSSettings.normalizedList
          )

          OptionalBoolPicker(
            title: "Direct Nameserver Follows Policy",
            value: $settings.dns.directNameserverFollowPolicy
          )

          EditableKeyValueList(
            title: "Nameserver Policy",
            keyPlaceholder: "geosite:cn",
            valuePlaceholder: "223.5.5.5",
            values: $settings.dns.nameserverPolicy,
            keyDraft: $policyKeyDraft,
            valueDraft: $policyValueDraft,
            keyValidator: TunDNSSettings.isValidPattern,
            valueValidator: TunDNSSettings.isValidResolver,
            normalizer: TunDNSSettings.normalizedMap
          )

          EditableKeyValueList(
            title: "Proxy Server Nameserver Policy",
            keyPlaceholder: "www.yournode.com",
            valuePlaceholder: "114.114.114.114",
            values: $settings.dns.proxyServerNameserverPolicy,
            keyDraft: $proxyPolicyKeyDraft,
            valueDraft: $proxyPolicyValueDraft,
            keyValidator: TunDNSSettings.isValidPattern,
            valueValidator: TunDNSSettings.isValidResolver,
            normalizer: TunDNSSettings.normalizedMap
          )

          EditableKeyValueList(
            title: "Hosts",
            keyPlaceholder: "router.lan",
            valuePlaceholder: "192.168.1.1",
            values: $settings.dns.hosts,
            keyDraft: $hostKeyDraft,
            valueDraft: $hostValueDraft,
            keyValidator: TunDNSSettings.isValidPattern,
            valueValidator: TunDNSSettings.isValidHostValue,
            normalizer: TunDNSSettings.normalizedMap
          )

          DisclosureGroup("Fallback Filter") {
            VStack(alignment: .leading, spacing: 12) {
              OptionalBoolPicker(title: "GeoIP", value: $settings.dns.fallbackFilter.geoIP)
              TextField("GeoIP Code", text: fallbackGeoIPCode)
                .textFieldStyle(.roundedBorder)

              EditableStringList(
                title: "Geosite",
                placeholder: "gfw",
                values: $settings.dns.fallbackFilter.geoSite,
                draft: $fallbackGeoSiteDraft,
                validator: TunDNSSettings.isValidPattern,
                normalizer: TunDNSSettings.normalizedList
              )

              EditableStringList(
                title: "IP CIDR",
                placeholder: "240.0.0.0/4",
                values: $settings.dns.fallbackFilter.ipCIDR,
                draft: $fallbackIPCIDRDraft,
                validator: TunSettings.isValidRouteExcludeCIDR,
                normalizer: NetworkExtensionRoutingSettings.normalizedRouteExcludeCIDRs
              )

              EditableStringList(
                title: "Domain",
                placeholder: "+.google.com",
                values: $settings.dns.fallbackFilter.domain,
                draft: $fallbackDomainDraft,
                validator: TunDNSSettings.isValidPattern,
                normalizer: TunDNSSettings.normalizedList
              )
            }
            .padding(.top, 8)
          }
        }
        .padding(.top, 8)
      }

      if let error = error ?? settings.validationError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      popoverActions(onCancel: onCancel, onSave: onSave, saveDisabled: settings.validationError != nil)
    }
  }

  private var fallbackGeoIPCode: Binding<String> {
    Binding(
      get: { settings.dns.fallbackFilter.geoIPCode ?? "" },
      set: { value in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.dns.fallbackFilter.geoIPCode = trimmed.isEmpty ? nil : trimmed
      }
    )
  }

  private static let customDNSPresetID = "custom"

  private var dnsPresetSelection: Binding<String> {
    Binding(
      get: {
        TunDNSSettings.presets.first { $0.settings == settings.dns }?.id ?? Self.customDNSPresetID
      },
      set: { id in
        guard let preset = TunDNSSettings.presets.first(where: { $0.id == id }) else { return }
        settings.dns = preset.settings
      }
    )
  }

  private var dnsPresetDescription: String {
    TunDNSSettings.presets.first { $0.settings == settings.dns }?.description
      ?? String(localized: "Custom app-managed DNS overlay.")
  }
}

private struct CurrentSystemProxySummary: View {
  let isActive: Bool
  let serviceAddress: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Current System Proxy")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 7) {
        summaryRow("Status") {
          Text(isActive ? "Enabled" : "Not Enabled")
            .foregroundStyle(isActive ? Color.green : Color.secondary)
        }

        summaryRow("Service Address") {
          Text(serviceAddress)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func summaryRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(LocalizedStringKey(title))
        .foregroundStyle(.secondary)
        .frame(width: 104, alignment: .trailing)

      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.callout)
  }
}

private struct OptionalBoolPicker: View {
  let title: String
  @Binding var value: Bool?

  var body: some View {
    Picker(title, selection: selection) {
      Text("Inherit").tag(0)
      Text("On").tag(1)
      Text("Off").tag(2)
    }
    .pickerStyle(.segmented)
  }

  private var selection: Binding<Int> {
    Binding(
      get: {
        switch value {
        case nil: 0
        case true: 1
        case false: 2
        }
      },
      set: { selected in
        switch selected {
        case 1:
          value = true
        case 2:
          value = false
        default:
          value = nil
        }
      }
    )
  }
}

private struct CompactIntegerStepperField: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  let step: Int
  @State private var draft = ""

  var body: some View {
    HStack(spacing: 6) {
      TextField("", text: $draft)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: 64)
        .onSubmit(commitDraft)
        .onChange(of: draft) { _, newValue in
          updateValueIfValid(newValue)
        }
        .onAppear(perform: syncDraft)
        .onChange(of: value) { _, _ in
          syncDraft()
        }

      Stepper("", value: clampedValue, in: range, step: step)
        .labelsHidden()
    }
    .fixedSize()
  }

  private var clampedValue: Binding<Int> {
    Binding(
      get: { clamped(value) },
      set: { value = clamped($0) }
    )
  }

  private func updateValueIfValid(_ text: String) {
    guard let parsed = Int(text), range.contains(parsed) else { return }
    value = parsed
  }

  private func commitDraft() {
    guard let parsed = Int(draft) else {
      syncDraft()
      return
    }
    value = clamped(parsed)
    syncDraft()
  }

  private func syncDraft() {
    let current = "\(clamped(value))"
    if draft != current {
      draft = current
    }
  }

  private func clamped(_ value: Int) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
  }
}

private struct EditableStringList: View {
  let title: String
  let placeholder: String
  @Binding var values: [String]
  @Binding var draft: String
  let validator: (String) -> Bool
  var normalizer: ([String]) -> [String] = SystemProxySettings.normalizedBypassDomains

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)

      WrappingTokenList(title: nil, values: values, removeAction: remove)

      HStack(spacing: 8) {
        TextField(placeholder, text: $draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        Button("Add", action: add)
          .disabled(!validator(draft))
      }
    }
  }

  private func add() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard validator(trimmed) else { return }
    values = normalizer(values + [trimmed])
    draft = ""
  }

  private func remove(_ value: String) {
    values.removeAll { $0 == value }
  }
}

private struct EditableKeyValueList: View {
  let title: String
  let keyPlaceholder: String
  let valuePlaceholder: String
  @Binding var values: [String: String]
  @Binding var keyDraft: String
  @Binding var valueDraft: String
  let keyValidator: (String) -> Bool
  let valueValidator: (String) -> Bool
  var normalizer: ([String: String]) -> [String: String] = TunDNSSettings.normalizedMap

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)

      if values.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        VStack(spacing: 6) {
          ForEach(values.keys.sorted(), id: \.self) { key in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(key)
                .font(.caption)
                .lineLimit(1)
              Spacer(minLength: 8)
              Text(values[key] ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
              Button {
                remove(key)
              } label: {
                Image(systemName: "xmark")
                  .font(.system(size: 9, weight: .bold))
              }
              .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
        }
      }

      HStack(spacing: 8) {
        TextField(keyPlaceholder, text: $keyDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        TextField(valuePlaceholder, text: $valueDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        Button("Add", action: add)
          .disabled(!canAdd)
      }
    }
  }

  private var canAdd: Bool {
    keyValidator(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
      && valueValidator(valueDraft.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func add() {
    let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = valueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard keyValidator(key), valueValidator(value) else { return }
    var next = values
    next[key] = value
    values = normalizer(next)
    keyDraft = ""
    valueDraft = ""
  }

  private func remove(_ key: String) {
    values.removeValue(forKey: key)
  }
}

private struct WrappingTokenList: View {
  let title: String?
  let values: [String]
  var removeAction: ((String) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title {
        Text(LocalizedStringKey(title))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if values.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
          ForEach(values, id: \.self) { value in
            HStack(spacing: 4) {
              Text(value)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
              if let removeAction {
                Button {
                  removeAction(value)
                } label: {
                  Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
          }
        }
      }
    }
  }
}

private func popoverHeader(_ title: String, systemImage: String) -> some View {
  Label(LocalizedStringKey(title), systemImage: systemImage)
    .font(.title3.weight(.semibold))
}

private func localizedDashboardText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}

private func popoverActions(onCancel: @escaping () -> Void, onSave: @escaping () -> Void, saveDisabled: Bool) -> some View {
  HStack {
    Spacer()
    Button("Cancel", action: onCancel)
      .keyboardShortcut(.cancelAction)
    Button("Save", action: onSave)
      .keyboardShortcut(.defaultAction)
      .disabled(saveDisabled)
  }
}

struct DashboardStatusPill: View {
  let title: String
  let value: String
  let symbolName: String
  let tint: Color

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(.caption, design: .rounded).weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(tint.opacity(0.20), lineWidth: 1)
    }
  }
}

struct DashboardMetricTile: View {
  let title: String
  let value: String
  let footnote: String?
  let symbolName: String
  let tint: Color
  var isLoading = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: symbolName)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 28, height: 28)
          .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        Spacer()
      }

      if isLoading {
        VStack(alignment: .leading, spacing: 7) {
          ClashMaxSkeletonBar(width: 74, height: 9)
          ClashMaxSkeletonBar(width: 104, height: 18)
          ClashMaxSkeletonBar(width: 86, height: 7)
        }
        .accessibilityHidden(true)
      } else {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(value)
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .contentTransition(.numericText())
            .changeEffect(.pulse(shape: RoundedRectangle(cornerRadius: 8), style: tint.opacity(0.18), count: 1), value: value)

          if let footnote {
            Text(footnote)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
    .dashboardCard()
  }
}

struct DashboardSectionHeader: View {
  let title: String
  let symbolName: String
  var trailing: String?

  var body: some View {
    HStack(spacing: 8) {
      Label(LocalizedStringKey(title), systemImage: symbolName)
        .font(.headline)
      Spacer()
      if let trailing {
        Text(trailing)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

struct DashboardEmptyRuntimeView: View {
  let title: String
  let symbolName: String
  var message: String?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbolName)
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 128)
    .frame(maxHeight: .infinity, alignment: .center)
  }
}

enum DashboardCardSurfaceStyle {
  static func surfaceID(for colorScheme: ColorScheme) -> String {
    colorScheme == .dark ? "dark-material-dashboard-card" : "light-flat-dashboard-card"
  }

  static func shadowOpacity(for colorScheme: ColorScheme) -> Double {
    colorScheme == .dark ? 0.16 : 0.04
  }

  static func strokeOpacity(for colorScheme: ColorScheme) -> Double {
    colorScheme == .dark ? 0.30 : 0.55
  }
}

struct DashboardCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  var interactive = false

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    let card = content
      .background {
        if colorScheme == .dark {
          ZStack {
            shape.fill(.regularMaterial)
            shape.fill(Color.primary.opacity(0.040))
          }
        } else {
          shape.fill(Color(nsColor: .windowBackgroundColor))
        }
      }
      .overlay {
        shape.stroke(
          Color(nsColor: .separatorColor).opacity(DashboardCardSurfaceStyle.strokeOpacity(for: colorScheme)),
          lineWidth: 1
        )
      }
      .shadow(color: .black.opacity(DashboardCardSurfaceStyle.shadowOpacity(for: colorScheme)), radius: colorScheme == .dark ? 16 : 10, x: 0, y: colorScheme == .dark ? 8 : 2)

    if colorScheme == .dark {
      card.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    } else {
      card
    }
  }
}

extension View {
  func dashboardCard(interactive: Bool = false) -> some View {
    modifier(DashboardCardModifier(interactive: interactive))
  }
}

func dashboardDurationString(from start: Date?, now: Date = Date()) -> String {
  guard let start else { return "--" }
  let interval = max(0, Int(now.timeIntervalSince(start)))
  let hours = interval / 3600
  let minutes = (interval % 3600) / 60
  let seconds = interval % 60
  if hours > 0 {
    return String(format: "%d:%02d:%02d", hours, minutes, seconds)
  }
  return String(format: "%d:%02d", minutes, seconds)
}

struct DashboardTrafficSparkline: View {
  let samples: [TrafficSample]

  var body: some View {
    Canvas { context, size in
      let inset: CGFloat = 8
      let plot = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
      let maxValue = max(samples.map { max($0.upload, $0.download) }.max() ?? 1, 1)

      var baseline = Path()
      baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
      baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
      context.stroke(baseline, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

      context.stroke(path(for: samples.map(\.download), maxValue: maxValue, in: plot), with: .color(.cyan), lineWidth: 2.4)
      context.stroke(path(for: samples.map(\.upload), maxValue: maxValue, in: plot), with: .color(.indigo), lineWidth: 2)
    }
  }

  private func path(for values: [Int], maxValue: Int, in rect: CGRect) -> Path {
    var path = Path()
    guard !values.isEmpty else { return path }

    for (index, value) in values.enumerated() {
      let progress = values.count == 1 ? 0 : CGFloat(index) / CGFloat(values.count - 1)
      let x = rect.minX + rect.width * progress
      let y = rect.maxY - rect.height * (CGFloat(value) / CGFloat(maxValue))
      if index == 0 {
        path.move(to: CGPoint(x: x, y: y))
      } else {
        path.addLine(to: CGPoint(x: x, y: y))
      }
    }

    return path
  }
}
