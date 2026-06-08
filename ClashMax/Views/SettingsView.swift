import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var settings: PersistedSettingsStore
  @EnvironmentObject private var appUpdateController: AppUpdateController
  private let bundledCoreInfo: BundledCoreInfo
  @State private var isRuleOverlayPresented = false
  @State private var isNetworkPoliciesPresented = false
  @State private var isBackupExportPresented = false
  @State private var isBackupRestorePresented = false

  init(bundledCoreInfo: BundledCoreInfo = BundledCoreInfo()) {
    self.bundledCoreInfo = bundledCoreInfo
  }

  private var latestHelperExitSummary: String? {
    appModel.helperLogs.reversed().first { line in
      line.localizedCaseInsensitiveContains("mihomo exited with code")
        || line.localizedCaseInsensitiveContains("last exit code")
    }
  }

  var body: some View {
    AdaptivePage(
      title: "Settings",
      subtitle: "Runtime overrides and system integration controls."
    ) {
      EmptyView()
    } content: {
      Form {
        Section("General") {
          SettingsToggleRow(
            "Developer Mode",
            description: "Show helper diagnostics and advanced recovery details.",
            isOn: Binding(
              get: { appModel.developerMode },
              set: { appModel.setDeveloperMode($0) }
            )
          )
          SettingsControlRow("Appearance", description: "Choose the app color scheme.") {
            Picker("Appearance", selection: $settings.appTheme) {
              ForEach(AppTheme.allCases) { theme in
                Text(theme.displayName).tag(theme)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220, alignment: .trailing)
          }
          SettingsControlRow(
            "Language",
            description: String(
              format: String(localized: "Current app language: %@. Change per-app language in macOS Language & Region, then reopen ClashMax if needed."),
              AppLocalization.currentLanguageDisplayName
            )
          ) {
            Button {
              AppLocalization.openLanguageAndRegionSettings()
            } label: {
              Label("Open Language & Region", systemImage: "globe")
            }
            .help("Open System Settings > General > Language & Region.")
          }
        }

        Section("Backup & Restore") {
          SettingsControlRow("Local Backup", description: backupRestoreDescription) {
            HStack(spacing: 8) {
              Button {
                isBackupExportPresented = true
              } label: {
                Label("Export", systemImage: "square.and.arrow.up")
              }

              Button {
                isBackupRestorePresented = true
              } label: {
                Label("Restore", systemImage: "arrow.clockwise")
              }
              .disabled(appModel.isCoreRunning)
              .help("Stop the core before restoring a backup.")
            }
          }
        }

        Section("Updates") {
          UpdateVersionRow(
            title: "App Package",
            description: appUpdateController.statusMessage,
            version: appUpdateController.versionSummary
          ) {
            CheckForUpdatesButton(updateController: appUpdateController)
          }

          UpdateVersionRow(
            title: "Bundled Core",
            description: bundledCoreInfo.statusMessage,
            version: bundledCoreInfo.versionSummary
          )
        }

        Section("Launch") {
          SettingsToggleRow(
            "Launch at Login",
            description: "Register ClashMax as a macOS login item.",
            isOn: Binding(
              get: { settings.launchSettings.launchAtLogin },
              set: { appModel.setLaunchAtLogin($0) }
            )
          )

          SettingsToggleRow(
            "Silent Start",
            description: "Hide the main window when launched by the login item.",
            isOn: Binding(
              get: { settings.launchSettings.silentStart },
              set: { appModel.setSilentStart($0) }
            )
          )
          .help("When enabled, ClashMax hides its main window during login-item startup. Open it from the menu bar when needed.")

          SettingsControlRow("Login Item Status", description: settings.launchSettings.statusMessage) {
            Button {
              appModel.openLoginItemsSettings()
            } label: {
              Label("Open Login Items", systemImage: "gearshape")
            }
            .help("Open System Settings > General > Login Items & Extensions.")
          }

        }

        if appModel.developerMode {
          Section("Shortcuts") {
            GlobalShortcutSettingsView(
              settings: $settings.globalShortcutSettings,
              registrationStatus: appModel.shortcutRegistrationStatus
            )
          }
        }

        Section("Runtime") {
          PortControl(
            title: "Mixed Port",
            description: "HTTP and SOCKS inbound port used by Mihomo.",
            value: Binding(
              get: { settings.overrides.mixedPort },
              set: { appModel.setMixedPort($0) }
            )
          )
          PortControl(
            title: "Controller Port",
            description: "Local controller API port bound to 127.0.0.1.",
            value: Binding(
              get: { settings.externalControllerSettings.port },
              set: { port in
                var controllerSettings = settings.externalControllerSettings
                controllerSettings.port = port
                _ = appModel.updateExternalControllerSettings(controllerSettings)
              }
            )
          )
          SettingsToggleRow(
            "Allow LAN",
            description: "Allow devices on this LAN to use the proxy port.",
            isOn: Binding(
              get: { settings.overrides.allowLan },
              set: { appModel.setAllowLAN($0) }
            )
          )
          SettingsToggleRow(
            "IPv6",
            description: "Enable Mihomo IPv6 support in the runtime profile.",
            isOn: Binding(
              get: { appModel.ipv6Enabled },
              set: { appModel.setIPv6Enabled($0) }
            )
          )
          SettingsToggleRow(
            "Enable DNS Override",
            description: "Write app-managed DNS options into the runtime profile.",
            isOn: Binding(
              get: { settings.overrides.dnsEnabled ?? false },
              set: { appModel.setDNSOverrideEnabled($0) }
            )
          )
          SettingsControlRow("Delay Test Mode", description: settings.delayTestSettings.mode.description) {
            Picker("Delay Test Mode", selection: $settings.delayTestSettings.mode) {
              ForEach(DelayTestMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180, alignment: .trailing)
          }
          SettingsToggleRow(
            "Unified Delay",
            description: "Run manual delay tests twice and use the second result to reduce handshake bias.",
            isOn: $settings.delayTestSettings.unifiedDelay
          )
          if appModel.developerMode {
            ExternalControlSettingsRow()
          }
          SettingsControlRow("Log Level", description: "Runtime logging verbosity.") {
            Picker("Log Level", selection: Binding(
              get: { settings.overrides.logLevel },
              set: { appModel.setLogLevel($0) }
            )) {
              Text("Info").tag("info")
              Text("Warning").tag("warning")
              Text("Error").tag("error")
              Text("Debug").tag("debug")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120, alignment: .trailing)
          }
          if let message = appModel.runtimeSettingsApplyStatusMessage {
            Text(message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        Section("Subscriptions") {
          SettingsControlRow(
            "User Agent",
            description: "Client identity sent when fetching subscription profiles."
          ) {
            TextField(
              "User Agent",
              text: Binding(
                get: { settings.subscriptionFetchSettings.userAgent },
                set: { settings.subscriptionFetchSettings.userAgent = $0 }
              )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 220, alignment: .trailing)
          }
          SettingsControlRow(
            "Request Timeout",
            description: "Network timeout used for each subscription fetch attempt."
          ) {
            NumberStepperField(
              accessibilityLabel: "Request Timeout",
              value: Binding(
                get: { settings.subscriptionFetchSettings.timeoutSeconds },
                set: { settings.subscriptionFetchSettings.timeoutSeconds = $0 }
              ),
              range: SubscriptionFetchSettings.minimumTimeoutSeconds...SubscriptionFetchSettings.maximumTimeoutSeconds,
              step: 5
            )
          }
          SettingsToggleRow(
            "Use Local Clash Proxy",
            description: "Retry failed direct fetches through ClashMax's current mixed-port on 127.0.0.1.",
            isOn: $settings.subscriptionFetchSettings.useLocalClashProxy
          )
          SettingsToggleRow(
            "Use System Proxy",
            description: "Retry failed subscription fetches through the current macOS proxy settings.",
            isOn: $settings.subscriptionFetchSettings.useSystemProxy
          )
          SettingsToggleRow(
            "Ignore TLS Errors",
            description: "Allow subscription servers with invalid certificates. Use only for trusted panels.",
            isOn: $settings.subscriptionFetchSettings.allowsInsecureTLS
          )
          SettingsToggleRow(
            "Automatic Updates",
            description: "Refresh subscriptions using per-profile policy, remote metadata, and the global fallback interval.",
            isOn: $settings.subscriptionFetchSettings.automaticUpdatesEnabled
          )
          SettingsControlRow(
            "Default Subscription Interval",
            description: "Fallback interval used when a subscription does not publish profile-update-interval."
          ) {
            NumberStepperField(
              accessibilityLabel: "Default Subscription Interval",
              value: Binding(
                get: { settings.subscriptionFetchSettings.defaultUpdateIntervalMinutes },
                set: { settings.subscriptionFetchSettings.defaultUpdateIntervalMinutes = SubscriptionUpdatePolicy.normalizedInterval($0) }
              ),
              range: SubscriptionUpdatePolicy.minimumIntervalMinutes...SubscriptionUpdatePolicy.maximumIntervalMinutes,
              step: 60
            )
          }
          SettingsControlRow(
            "Background Check Interval",
            description: "How often ClashMax wakes to check whether any subscription is due."
          ) {
            NumberStepperField(
              accessibilityLabel: "Background Check Interval",
              value: Binding(
                get: { settings.subscriptionFetchSettings.backgroundCheckIntervalMinutes },
                set: { settings.subscriptionFetchSettings.backgroundCheckIntervalMinutes = SubscriptionUpdatePolicy.normalizedInterval($0) }
              ),
              range: SubscriptionUpdatePolicy.minimumIntervalMinutes...SubscriptionUpdatePolicy.maximumIntervalMinutes,
              step: 30
            )
          }
          SettingsControlRow(
            "Retry Backoff Cap",
            description: "Maximum delay after repeated subscription update failures."
          ) {
            NumberStepperField(
              accessibilityLabel: "Retry Backoff Cap",
              value: Binding(
                get: { settings.subscriptionFetchSettings.retryCapMinutes },
                set: { settings.subscriptionFetchSettings.retryCapMinutes = SubscriptionUpdatePolicy.normalizedInterval($0) }
              ),
              range: SubscriptionUpdatePolicy.minimumIntervalMinutes...SubscriptionUpdatePolicy.maximumIntervalMinutes,
              step: 30
            )
          }
          SettingsToggleRow(
            "Notify Update Failures",
            description: "Show a macOS notification when automatic subscription refresh fails.",
            isOn: $settings.subscriptionFetchSettings.notifyOnUpdateFailure
          )
        }

        Section("Rules") {
          SettingsControlRow("Rule Overlay", description: settings.ruleOverlaySettings.summary) {
            Button {
              isRuleOverlayPresented = true
            } label: {
              Label("Configure", systemImage: "slider.horizontal.3")
            }
            .popover(isPresented: $isRuleOverlayPresented, arrowEdge: .bottom) {
              RuleOverlaySettingsPopover(settings: $settings.ruleOverlaySettings)
                .frame(width: 560)
                .padding(18)
            }
          }
        }

        Section("System") {
          SettingsControlRow("Proxy Routing", description: "Routing mode used when the core starts.") {
            Picker("Proxy Routing", selection: Binding(
              get: { settings.proxyRoutingMode },
              set: { appModel.requestProxyRoutingMode($0) }
            )) {
              ForEach(ProxyRoutingMode.allCases) { mode in
                Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180, alignment: .trailing)
            .help("Start uses this routing mode.")
          }

          SettingsControlRow("Network Policies", description: settings.networkPolicySettings.summary) {
            Button {
              isNetworkPoliciesPresented = true
            } label: {
              Label("Configure", systemImage: "wifi.router")
            }
            .popover(isPresented: $isNetworkPoliciesPresented, arrowEdge: .bottom) {
              NetworkPolicySettingsPopover(
                settings: $settings.networkPolicySettings,
                currentSSID: appModel.currentNetworkSSID,
                statusMessage: appModel.networkPolicyStatusMessage,
                lastAppliedPolicyID: appModel.lastAppliedNetworkPolicyID,
                onRefresh: {
                  appModel.refreshCurrentNetworkPolicyState()
                },
                onApplyCurrent: {
                  appModel.applyMatchingNetworkPolicyForCurrentNetwork()
                },
                onApplyRule: { rule in
                  appModel.applyNetworkPolicy(rule)
                }
              )
                .frame(width: 560)
                .padding(18)
                .onAppear {
                  appModel.refreshCurrentNetworkPolicyState()
                }
            }
          }

          if settings.proxyRoutingMode == .tun {
            SettingsControlRow("TUN Helper Status", description: appModel.tunHelperPreparationState.message) {
              ViewThatFits(in: .horizontal) {
                helperActionButtons
                helperActionButtonRows
              }
            }
            .onAppear {
              appModel.refreshHelperRegistrationStatus()
            }

            HelperStatusDetailView(
              detail: appModel.tunHelperStatusDetail,
              logCount: appModel.helperLogs.count,
              latestExitSummary: latestHelperExitSummary
            )

            if settings.developerMode {
              Text("LaunchDaemon approval is managed by macOS. Registering may open System Settings instead of showing an app permission sheet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
              if !appModel.helperLogs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                  ForEach(appModel.helperLogs.suffix(6), id: \.self) { line in
                    Text(line)
                      .font(.system(.caption, design: .monospaced))
                      .lineLimit(2)
                  }
                }
              }
            }
          } else if settings.proxyRoutingMode == .neProxy {
            SettingsControlRow(
              "TUN Helper",
              description: "NE Proxy mode does not touch the privileged TUN helper."
            ) {
              Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
            }
          } else {
            SettingsControlRow(
              "TUN Helper",
              description: "System Proxy mode does not need a privileged helper. Switch to TUN if you want VPN-style routing for non-HTTP traffic."
            ) {
              Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
            }
          }
        }

        if settings.proxyRoutingMode == .neProxy {
          Section("NE Proxy") {
            SettingsControlRow("System Extension", description: appModel.networkExtensionController.statusMessage) {
              ViewThatFits(in: .horizontal) {
                networkExtensionActionButtons
                networkExtensionActionButtonRows
              }
            }
            .onAppear {
              appModel.refreshNetworkExtensionStatus()
            }

            SettingsControlRow(
              "Transparent Proxy Status",
              description: appModel.networkExtensionController.tunnelStatusMessage
            ) {
              Label(
                appModel.networkExtensionController.vpnStatus.displayName,
                systemImage: networkExtensionStatusSymbol
              )
              .foregroundStyle(appModel.networkExtensionController.vpnStatus.isActive ? .green : .secondary)
            }

            SettingsControlRow(
              "NE Diagnostics",
              description: networkExtensionDiagnosticsSummary
            ) {
              Button {
                appModel.refreshNetworkExtensionStatus()
              } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
              }
            }

            if let error = appModel.networkExtensionController.recentError {
              Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }

            if let error = appModel.networkExtensionSystemDNSState.errorMessage {
              Text(String(format: String(localized: "DNS: %@"), error))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        appModel.refreshLaunchSettings()
      }
    }
    .sheet(isPresented: $isBackupExportPresented) {
      BackupExportSheet(
        onCancel: { isBackupExportPresented = false },
        onExport: { includeSecrets, password, passwordConfirmation in
          isBackupExportPresented = false
          appModel.exportBackup(
            includeSecrets: includeSecrets,
            password: password,
            passwordConfirmation: passwordConfirmation
          )
        }
      )
    }
    .sheet(isPresented: $isBackupRestorePresented, onDismiss: {
      appModel.clearPendingBackupRestore()
    }) {
      BackupRestoreSheet(
        onCancel: {
          appModel.clearPendingBackupRestore()
          isBackupRestorePresented = false
        },
        onRestoreFinished: {
          isBackupRestorePresented = false
        }
      )
      .environmentObject(appModel)
    }
  }

  private var backupRestoreDescription: String {
    if appModel.isCoreRunning {
      return String(localized: "Export is available. Stop the core before restoring.")
    }
    if let message = appModel.backupRestoreStatusMessage {
      return message
    }
    return String(localized: "Export or merge-restore profiles, settings, rules, provider options, and proxy selections.")
  }

  private var isHelperBusy: Bool {
    appModel.tunHelperPreparationState == .checking
  }

  private var isTunnelActive: Bool {
    appModel.tunEnabled || appModel.tunnelCoreRunning
  }

  private var helperBusyIndicator: some View {
    Group {
      if isHelperBusy {
        ProgressView()
          .controlSize(.small)
          .help("Talking to the TUN helper…")
      }
    }
  }

  private var helperActionButtons: some View {
    HStack(spacing: 8) {
      helperBusyIndicator
      helperRegisterButton
      helperOpenSettingsButton
      helperRepairButton
      helperStatusButton
      if settings.developerMode {
        helperLogsButton
        helperUnregisterButton
        helperResetStateButton
      }
    }
  }

  private var helperActionButtonRows: some View {
    VStack(alignment: .trailing, spacing: 8) {
      HStack(spacing: 8) {
        helperRegisterButton
        helperOpenSettingsButton
        helperRepairButton
      }
      HStack(spacing: 8) {
        helperBusyIndicator
        helperStatusButton
        if settings.developerMode {
          helperLogsButton
        }
      }
      if settings.developerMode {
        HStack(spacing: 8) {
          helperUnregisterButton
          helperResetStateButton
        }
      }
    }
  }

  private var helperRegisterButton: some View {
    Button {
      appModel.registerHelper()
    } label: {
      Label("Register", systemImage: "checkmark.shield")
    }
    .disabled(isHelperBusy)
  }

  private var helperOpenSettingsButton: some View {
    Button {
      appModel.openHelperApprovalSettings()
    } label: {
      Label("Open Settings", systemImage: "gearshape")
    }
    .help("Open System Settings > General > Login Items & Extensions.")
  }

  private var helperRepairButton: some View {
    Button {
      appModel.repairHelperRegistration()
    } label: {
      Label("Repair", systemImage: "wrench.and.screwdriver")
    }
    .disabled(isHelperBusy)
  }

  private var helperStatusButton: some View {
    Button {
      appModel.refreshHelperStatus()
    } label: {
      Label("Status", systemImage: "waveform.path.ecg")
    }
    .disabled(isHelperBusy)
  }

  private var helperLogsButton: some View {
    Button {
      appModel.refreshHelperLogs()
    } label: {
      Label("Logs", systemImage: "text.alignleft")
    }
  }

  private var helperUnregisterButton: some View {
    Button {
      appModel.unregisterHelper()
    } label: {
      Label("Unregister", systemImage: "xmark.shield")
    }
    .disabled(isHelperBusy || isTunnelActive)
    .help("Unregister the privileged TUN helper.")
  }

  private var helperResetStateButton: some View {
    Button {
      appModel.resetHelperState()
    } label: {
      Label("Reset State", systemImage: "arrow.counterclockwise")
    }
    .disabled(isHelperBusy || isTunnelActive)
    .help("Forget the recorded helper fingerprint without unregistering the LaunchDaemon.")
  }

  private var networkExtensionActionButtons: some View {
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
    }
  }

  private var networkExtensionStatusSymbol: String {
    switch appModel.networkExtensionController.vpnStatus {
    case .notConfigured:
      "checkmark.circle"
    case .connecting, .connected, .reasserting, .disconnecting:
      "network"
    case .invalid, .disconnected:
      "xmark.circle"
    }
  }

  private var networkExtensionDiagnosticsSummary: String {
    let diagnostics = appModel.networkExtensionController.diagnostics
    let dnsRuntime = appModel.networkExtensionRoutingSettings.dnsFakeIPEnabled
      ? String(localized: "fake-ip")
      : String(localized: "profile")
    return String(
      format: String(localized: "TCP %lld, UDP %lld, DNS captures %lld, DNS datagrams %lld, SOCKS failures %lld, DNS %@, system DNS %@."),
      diagnostics.activeTCPBridgeCount,
      diagnostics.activeUDPBridgeCount,
      diagnostics.dnsCaptureCount,
      diagnostics.dnsDatagramCount,
      diagnostics.socksHandshakeFailureCount,
      dnsRuntime,
      appModel.networkExtensionSystemDNSState.displayName
    )
  }

  private var networkExtensionActionButtonRows: some View {
    VStack(alignment: .trailing, spacing: 8) {
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
      }
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
    }
  }
}

private struct BackupExportSheet: View {
  @State private var includeSecrets = false
  @State private var password = ""
  @State private var passwordConfirmation = ""
  let onCancel: () -> Void
  let onExport: (Bool, String?, String?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Export ClashMax Backup", systemImage: "square.and.arrow.up")
        .font(.headline)

      Toggle("Include encrypted secrets", isOn: $includeSecrets)

      Text(
        includeSecrets
          ? "The password protects subscription secrets and full profile YAML. The backup also contains redacted YAML for compatibility."
          : "Profile YAML may contain proxy passwords, UUIDs, tokens, and provider URLs. Passwordless exports redact detected YAML credentials."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if includeSecrets {
        SecureField("Backup Password", text: $password)
          .textFieldStyle(.roundedBorder)
        SecureField("Confirm Password", text: $passwordConfirmation)
          .textFieldStyle(.roundedBorder)
        if let passwordError {
          Label(passwordError, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
        Button("Export") {
          onExport(includeSecrets, includeSecrets ? password : nil, includeSecrets ? passwordConfirmation : nil)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(passwordError != nil)
      }
    }
    .padding(20)
    .frame(width: 380)
  }

  private var passwordError: String? {
    guard includeSecrets else { return nil }
    if password.isEmpty {
      return String(localized: "Password is required for encrypted secret export.")
    }
    if password != passwordConfirmation {
      return String(localized: "Passwords do not match.")
    }
    return nil
  }
}

private struct BackupRestoreSheet: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var password = ""
  @State private var isRestoring = false
  let onCancel: () -> Void
  let onRestoreFinished: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Restore ClashMax Backup", systemImage: "arrow.clockwise")
        .font(.headline)

      if let preview = appModel.pendingBackupRestorePreview {
        backupPreview(preview)
      } else {
        CenteredUnavailableState(
          title: "No backup selected",
          systemImage: "externaldrive.badge.plus",
          message: "Choose a .clashmax-backup file to preview before restore."
        )
        Button {
          appModel.chooseBackupForRestore()
        } label: {
          Label("Choose Backup", systemImage: "folder")
        }
      }

      if let preview = appModel.pendingBackupRestorePreview, preview.hasEncryptedSecrets {
        SecureField("Backup Password", text: $password)
          .textFieldStyle(.roundedBorder)
        Text("Leave blank to restore without encrypted secrets.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
        Button {
          appModel.chooseBackupForRestore()
        } label: {
          Label("Choose", systemImage: "folder")
        }
        Button("Restore") {
          restore()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(appModel.pendingBackupRestorePreview == nil || appModel.isCoreRunning || isRestoring)
      }
    }
    .padding(20)
    .frame(width: 430)
  }

  private func backupPreview(_ preview: BackupRestorePreview) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(preview.fileName)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      BackupRestoreFactRow(title: "Profiles", value: "\(preview.profileCount)")
      BackupRestoreFactRow(title: "Settings", value: preview.hasSettings ? String(localized: "Included") : String(localized: "Missing"))
      BackupRestoreFactRow(title: "Proxy Selections", value: "\(preview.proxySelectionProfileCount)")
      BackupRestoreFactRow(
        title: "Secrets",
        value: preview.hasEncryptedSecrets
          ? String(localized: "Encrypted")
          : String(format: String(localized: "%lld omitted"), Int64(preview.omittedSecretSummary.totalCount))
      )
    }
  }

  private func restore() {
    isRestoring = true
    Task { @MainActor in
      let restored = await appModel.restorePendingBackup(password: password.isEmpty ? nil : password)
      isRestoring = false
      if restored {
        onRestoreFinished()
      }
    }
  }
}

private struct BackupRestoreFactRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(localizedSettingsText(title))
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .fontWeight(.medium)
    }
    .font(.callout)
  }
}

private struct GlobalShortcutSettingsView: View {
  @Binding var settings: GlobalShortcutSettings
  let registrationStatus: GlobalShortcutRegistrationStatus?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Configure global shortcuts for high-frequency proxy actions. Shortcuts are disabled until a key is set and enabled.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(GlobalShortcutAction.allCases) { action in
          GlobalShortcutBindingRow(action: action, settings: $settings)
        }
      }

      if let error = settings.validationError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }

      if let error = registrationStatus?.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(3)
      }
    }
  }
}

private struct GlobalShortcutBindingRow: View {
  let action: GlobalShortcutAction
  @Binding var settings: GlobalShortcutSettings
  @State private var draft = ""
  @State private var parseError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Label(action.displayName, systemImage: action.symbolName)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        TextField("cmd+shift+p", text: $draft)
          .textFieldStyle(.roundedBorder)
          .frame(width: 142)
          .onSubmit(applyDraft)
          .onAppear {
            draft = binding.shortcut?.storageString ?? ""
          }
          .onChange(of: draft) { _, _ in
            parseError = nil
          }

        Button {
          applyDraft()
        } label: {
          Image(systemName: "checkmark")
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help("Apply shortcut")

        Button {
          draft = ""
          parseError = nil
          settings.set(nil, for: action, enabled: false)
        } label: {
          Image(systemName: "xmark")
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help("Clear shortcut")

        Toggle("", isOn: Binding(
          get: { binding.enabled },
          set: { enabled in
            settings.set(binding.shortcut, for: action, enabled: enabled)
          }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(binding.shortcut == nil)
        .help("Enable global shortcut")
      }

      if let parseError {
        Label(parseError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
    .font(.caption)
  }

  private var binding: GlobalShortcutBinding {
    settings.mergedBindings.first { $0.action == action } ?? GlobalShortcutBinding(action: action)
  }

  private func applyDraft() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      settings.set(nil, for: action, enabled: false)
      parseError = nil
      return
    }
    guard let shortcut = KeyboardShortcutDescriptor(string: trimmed) else {
      parseError = String(localized: "Shortcut must contain one key and at least one modifier.")
      return
    }
    draft = shortcut.storageString
    parseError = nil
    settings.set(shortcut, for: action, enabled: true)
  }
}

private struct NetworkPolicySettingsPopover: View {
  @Binding var settings: NetworkPolicySettings
  let currentSSID: String?
  let statusMessage: String?
  let lastAppliedPolicyID: NetworkPolicyRule.ID?
  let onRefresh: () -> Void
  let onApplyCurrent: () -> Void
  let onApplyRule: (NetworkPolicyRule) -> Void
  @State private var name = ""
  @State private var ssid = ""
  @State private var proxyRoutingMode = ProxyRoutingMode.systemProxy
  @State private var enableSystemProxy = true
  @State private var autoStartRuntime = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      popoverHeader("Network Policies", systemImage: "wifi.router")

      Toggle("Apply saved policies automatically on network changes", isOn: $settings.autoApplyEnabled)
        .toggleStyle(.checkbox)

      Picker("When no SSID matches", selection: $settings.unmatchedBehavior) {
        ForEach(NetworkPolicyUnmatchedBehavior.allCases) { behavior in
          Text(behavior.displayName).tag(behavior)
        }
      }
      .pickerStyle(.menu)
      Text(settings.unmatchedBehavior.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        Label(statusMessage ?? String(localized: "Current network not checked."), systemImage: currentSSID == nil ? "wifi.slash" : "wifi")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer()
        Button {
          onRefresh()
        } label: {
          Image(systemName: "arrow.clockwise")
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help("Refresh current network")

        Button {
          onApplyCurrent()
        } label: {
          Label("Apply Current", systemImage: "bolt")
        }
        .disabled(settings.rules.isEmpty)
        .help("Apply the saved policy matching the current Wi-Fi SSID.")
      }

      VStack(alignment: .leading, spacing: 10) {
        TextField("Policy Name", text: $name)
          .textFieldStyle(.roundedBorder)
        TextField("Wi-Fi SSID", text: $ssid)
          .textFieldStyle(.roundedBorder)

        Picker("Routing", selection: $proxyRoutingMode) {
          ForEach(ProxyRoutingMode.allCases) { mode in
            Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        Toggle("Enable System Proxy when this policy selects System Proxy", isOn: $enableSystemProxy)
          .toggleStyle(.checkbox)
          .disabled(proxyRoutingMode != .systemProxy)

        Toggle("Start runtime automatically for this policy", isOn: $autoStartRuntime)
          .toggleStyle(.checkbox)

        HStack {
          if let error = draftRule.validationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          }
          Spacer()
          Button {
            addRule()
          } label: {
            Label("Add Policy", systemImage: "plus")
          }
          .disabled(draftRule.validationError != nil)
        }
      }

      Divider()

      if settings.rules.isEmpty {
        Text("No network policies")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(settings.rules.enumerated()), id: \.element.id) { index, rule in
            networkPolicyRow(rule, at: index)
          }
        }
      }
    }
  }

  private var draftRule: NetworkPolicyRule {
    NetworkPolicyRule(
      name: name,
      ssid: ssid,
      proxyRoutingMode: proxyRoutingMode,
      enableSystemProxy: proxyRoutingMode == .systemProxy && enableSystemProxy,
      autoStartRuntime: autoStartRuntime
    )
  }

  private func networkPolicyRow(_ rule: NetworkPolicyRule, at index: Int) -> some View {
    HStack(spacing: 10) {
      Image(systemName: rule.proxyRoutingMode.symbolName)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(rule.name)
          .font(.callout)
          .lineLimit(1)
        Text(rule.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer()
      if lastAppliedPolicyID == rule.id {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .help("Last applied policy")
      }
      Button {
        onApplyRule(rule)
      } label: {
        Image(systemName: "play.fill")
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless)
      .help("Apply policy")
      Button {
        removeRule(at: index)
      } label: {
        Image(systemName: "trash")
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless)
      .help("Remove policy")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func addRule() {
    let rule = draftRule
    guard rule.validationError == nil else { return }
    settings.rules.append(rule)
    name = ""
    ssid = ""
    proxyRoutingMode = .systemProxy
    enableSystemProxy = true
    autoStartRuntime = false
  }

  private func removeRule(at index: Int) {
    guard settings.rules.indices.contains(index) else { return }
    settings.rules.remove(at: index)
  }
}

private struct ExternalDashboardProfilesPopover: View {
  let profiles: [ExternalDashboardProfile]
  @Binding var name: String
  @Binding var urlString: String
  @Binding var readOnly: Bool
  @Binding var secret: String
  @Binding var trustedForSecretAutofill: Bool
  @Binding var error: String?
  let onAdd: () -> Void
  let onDelete: (ExternalDashboardProfile) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      popoverHeader("External Dashboards", systemImage: "rectangle.3.group")

      Text("Dashboard secrets are stored in Keychain. Saved profiles keep only the Keychain account reference.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 10) {
        TextField("Name", text: $name)
          .textFieldStyle(.roundedBorder)
        TextField("Dashboard URL", text: $urlString)
          .textFieldStyle(.roundedBorder)
        Toggle("Read-only dashboard", isOn: $readOnly)
          .toggleStyle(.checkbox)
          .onChange(of: readOnly) { _, newValue in
            if newValue {
              trustedForSecretAutofill = false
            }
          }
        SecureField("Dashboard Secret", text: $secret)
          .textFieldStyle(.roundedBorder)
          .disabled(readOnly)
        if !readOnly {
          Toggle("Trust this dashboard to receive the API secret automatically", isOn: $trustedForSecretAutofill)
            .toggleStyle(.checkbox)
          Text("Trusted read-write dashboards receive the secret in the URL fragment. Remote dashboards that are not trusted open without the secret, and the menu offers one-time copy instead.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
          if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          }
          Spacer()
          Button {
            onAdd()
          } label: {
            Label("Add Dashboard", systemImage: "plus")
          }
        }
      }

      Divider()

      if profiles.isEmpty {
        Text("No dashboards")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(profiles) { profile in
            HStack(spacing: 10) {
              Image(systemName: profile.readOnly ? "eye" : "pencil")
                .foregroundStyle(.secondary)
                .frame(width: 18)
              VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                  .lineLimit(1)
                Text(profile.url.absoluteString)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Spacer()
              if profile.secretAccount != nil {
                Image(systemName: "key")
                  .foregroundStyle(.secondary)
                  .help("Secret stored in Keychain")
              }
              if !profile.readOnly && profile.trustedForSecretAutofill {
                Image(systemName: "shield.checkered")
                  .foregroundStyle(.secondary)
                  .help("Trusted for automatic secret autofill")
              }
              Button {
                onDelete(profile)
              } label: {
                Image(systemName: "trash")
                  .frame(width: 22, height: 22)
              }
              .buttonStyle(.borderless)
              .help("Remove dashboard")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
        }
      }
    }
  }
}

struct RuleOverlaySettingsPopover: View {
  @Binding var settings: RuleOverlaySettings

  var body: some View {
    RuleOverlaySettingsEditor(settings: $settings)
  }
}

struct RuleOverlaySettingsEditor: View {
  @Binding var settings: RuleOverlaySettings
  let showsHeader: Bool
  let showsEnableToggle: Bool
  @State private var position = RuleOverlayPosition.prepend
  @State private var ruleCategory = RuleBuilderCategory.domain
  @State private var kind = ManagedRuleOverlayRule.Kind.domainSuffix
  @State private var value = ""
  @State private var policy = "DIRECT"
  @State private var noResolve = false
  @State private var disabledRuleMode = RuleDisableMatchMode.contains
  @State private var disabledRulePattern = ""

  init(
    settings: Binding<RuleOverlaySettings>,
    showsHeader: Bool = true,
    showsEnableToggle: Bool = true
  ) {
    self._settings = settings
    self.showsHeader = showsHeader
    self.showsEnableToggle = showsEnableToggle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if showsHeader {
        popoverHeader("Rule Overlay", systemImage: "list.bullet.rectangle")
      }

      if showsEnableToggle {
        Toggle("Enable Rule Overlay", isOn: $settings.enabled)
          .toggleStyle(.switch)
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) {
          ruleInputSection
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
          disabledRuleInputSection
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
        }

        VStack(alignment: .leading, spacing: 12) {
          ruleInputSection
          disabledRuleInputSection
        }
      }

      Divider()

      ruleListsSection
    }
  }

  private var ruleListsSection: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        RuleOverlayRuleList(title: "Before Profile Rules", rules: $settings.prependRules)
          .frame(minWidth: 180, maxWidth: .infinity, alignment: .topLeading)
        RuleDisableMatcherList(matchers: $settings.disabledRuleMatchers)
          .frame(minWidth: 180, maxWidth: .infinity, alignment: .topLeading)
        RuleOverlayRuleList(title: "After Profile Rules", rules: $settings.appendRules)
          .frame(minWidth: 180, maxWidth: .infinity, alignment: .topLeading)
      }

      VStack(alignment: .leading, spacing: 12) {
        RuleOverlayRuleList(title: "Before Profile Rules", rules: $settings.prependRules)
        RuleDisableMatcherList(matchers: $settings.disabledRuleMatchers)
        RuleOverlayRuleList(title: "After Profile Rules", rules: $settings.appendRules)
      }
    }
  }

  private var ruleInputSection: some View {
    RuleOverlayEditorSection(title: "Add Rule", systemImage: "plus.circle") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Position", selection: $position) {
          ForEach(RuleOverlayPosition.allCases) { position in
            Text(position.displayName).tag(position)
          }
        }
        .pickerStyle(.segmented)

        Picker("Rule Category", selection: $ruleCategory) {
          ForEach(RuleBuilderCategory.allCases) { category in
            Text(category.displayName).tag(category)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: ruleCategory) { _, category in
          kind = category.defaultKind
          prepareDraftForKind(kind)
        }

        Picker("Rule Type", selection: $kind) {
          ForEach(ruleCategory.kinds) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: kind) { _, nextKind in
          ruleCategory = RuleBuilderCategory.category(for: nextKind)
          prepareDraftForKind(nextKind)
        }

        if kind == .subRule {
          SubRuleConditionPicker(condition: $value)
        } else if kind.requiresValue {
          TextField(LocalizedStringKey(kind.valuePlaceholder), text: $value)
            .textFieldStyle(.roundedBorder)
        }

        TextField(LocalizedStringKey(kind.policyPlaceholder), text: $policy)
          .textFieldStyle(.roundedBorder)

        Text("Runtime: \(draftRule.runtimeRule)")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)

        if kind.allowsNoResolve {
          Toggle("No Resolve", isOn: $noResolve)
            .toggleStyle(.checkbox)
        }

        HStack {
          if let error = draftRule.validationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          }
          Spacer()
          Button {
            addRule()
          } label: {
            Label("Add Rule", systemImage: "plus")
          }
          .disabled(!settings.enabled || draftRule.validationError != nil)
        }
      }
    }
  }

  private var disabledRuleInputSection: some View {
    RuleOverlayEditorSection(title: "Disable Profile Rule", systemImage: "nosign") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Match", selection: $disabledRuleMode) {
          ForEach(RuleDisableMatchMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.segmented)

        TextField("Rule pattern", text: $disabledRulePattern)
          .textFieldStyle(.roundedBorder)

        HStack {
          if let error = draftDisabledRuleMatcher.validationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          }
          Spacer()
          Button {
            addDisabledRuleMatcher()
          } label: {
            Label("Disable Rule", systemImage: "nosign")
          }
          .disabled(!settings.enabled || draftDisabledRuleMatcher.validationError != nil)
        }
      }
    }
  }

  private var draftRule: ManagedRuleOverlayRule {
    ManagedRuleOverlayRule(kind: kind, value: value, policy: policy, noResolve: noResolve)
  }

  private var draftDisabledRuleMatcher: ManagedRuleDisableMatcher {
    ManagedRuleDisableMatcher(mode: disabledRuleMode, pattern: disabledRulePattern)
  }

  private func addRule() {
    let rule = draftRule
    guard rule.validationError == nil else { return }
    switch position {
    case .prepend:
      settings.prependRules.append(rule)
    case .append:
      settings.appendRules.append(rule)
    }
    value = ""
    if !kind.allowsNoResolve {
      noResolve = false
    }
    if kind == .subRule {
      value = "NETWORK,tcp"
    }
  }

  private func addDisabledRuleMatcher() {
    let matcher = draftDisabledRuleMatcher
    guard matcher.validationError == nil else { return }
    settings.disabledRuleMatchers.append(matcher)
    disabledRulePattern = ""
  }

  private func prepareDraftForKind(_ nextKind: ManagedRuleOverlayRule.Kind) {
    if !nextKind.allowsNoResolve {
      noResolve = false
    }
    if nextKind == .subRule {
      let candidate = ManagedRuleOverlayRule(kind: .subRule, value: value, policy: policy)
      if candidate.validationError != nil {
        value = "NETWORK,tcp"
      }
    } else if value.contains(",") {
      value = ""
    }
  }
}

private enum RuleOverlayPosition: String, CaseIterable, Identifiable {
  case prepend
  case append

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .prepend:
      return String(localized: "Before profile")
    case .append:
      return String(localized: "After profile")
    }
  }
}

private enum RuleBuilderCategory: String, CaseIterable, Identifiable {
  case domain
  case ip
  case source
  case port
  case provider
  case process
  case geo
  case fallback

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .domain:
      String(localized: "Domain")
    case .ip:
      String(localized: "IP")
    case .source:
      String(localized: "Source")
    case .port:
      String(localized: "Port")
    case .provider:
      String(localized: "Provider")
    case .process:
      String(localized: "Process")
    case .geo:
      String(localized: "Geo")
    case .fallback:
      String(localized: "Fallback")
    }
  }

  var kinds: [ManagedRuleOverlayRule.Kind] {
    switch self {
    case .domain:
      [.domain, .domainSuffix, .domainKeyword]
    case .ip:
      [.ipCIDR, .ipCIDR6]
    case .source:
      [.srcGeoIP, .srcIPASN, .srcIPCIDR, .srcIPSuffix]
    case .port:
      [.dstPort, .srcPort, .inPort]
    case .provider:
      [.ruleSet, .subRule]
    case .process:
      [.processName, .processPath]
    case .geo:
      [.geoSite, .geoIP]
    case .fallback:
      [.match]
    }
  }

  var defaultKind: ManagedRuleOverlayRule.Kind {
    kinds[0]
  }

  static func category(for kind: ManagedRuleOverlayRule.Kind) -> RuleBuilderCategory {
    allCases.first { $0.kinds.contains(kind) } ?? .domain
  }
}

private struct SubRuleConditionPicker: View {
  @Binding var condition: String

  var body: some View {
    Picker("Condition", selection: networkBinding) {
      ForEach(SubRuleNetworkCondition.allCases) { condition in
        Text(condition.displayName).tag(condition)
      }
    }
    .pickerStyle(.segmented)
  }

  private var networkBinding: Binding<SubRuleNetworkCondition> {
    Binding(
      get: {
        SubRuleNetworkCondition(condition: condition) ?? .tcp
      },
      set: { nextValue in
        condition = nextValue.ruleCondition
      }
    )
  }
}

private enum SubRuleNetworkCondition: String, CaseIterable, Identifiable {
  case tcp
  case udp

  var id: String { rawValue }

  init?(condition: String) {
    let parts = condition
      .split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard parts.count == 2,
          parts[0].caseInsensitiveCompare("NETWORK") == .orderedSame
    else {
      return nil
    }
    self.init(rawValue: parts[1].lowercased())
  }

  var displayName: String {
    switch self {
    case .tcp:
      return String(localized: "Network TCP")
    case .udp:
      return String(localized: "Network UDP")
    }
  }

  var ruleCondition: String {
    "NETWORK,\(rawValue)"
  }
}

private struct RuleOverlayEditorSection<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let title: LocalizedStringResource
  let systemImage: String
  let content: Content

  init(title: LocalizedStringResource, systemImage: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text(title)
      } icon: {
        Image(systemName: systemImage)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .lineLimit(1)

      content
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(RuleOverlaySurface.section(for: colorScheme), in: shape)
    .overlay {
      shape.strokeBorder(RuleOverlaySurface.border(for: colorScheme).opacity(0.72), lineWidth: 1)
    }
  }
}

private struct RuleOverlayRuleList: View {
  let title: LocalizedStringResource
  @Binding var rules: [ManagedRuleOverlayRule]
  @State private var draggedRuleID: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)

      if rules.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
          RuleOverlayEditableRuleRow(
            rule: Binding(
              get: { rules[index] },
              set: { rules[index] = $0 }
            ),
            canMoveUp: index > 0,
            canMoveDown: index < rules.count - 1,
            onMoveUp: { moveRule(from: index, by: -1) },
            onMoveDown: { moveRule(from: index, by: 1) },
            onDuplicate: { duplicateRule(at: index) },
            onDelete: { rules.remove(at: index) }
          )
          .onDrag {
            draggedRuleID = rule.id
            return NSItemProvider(object: rule.id.uuidString as NSString)
          }
          .onDrop(
            of: [UTType.text],
            delegate: RuleOverlayRuleDropDelegate(target: rule, rules: $rules, draggedRuleID: $draggedRuleID)
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func moveRule(from index: Int, by offset: Int) {
    let destination = index + offset
    guard rules.indices.contains(index), rules.indices.contains(destination) else { return }
    rules.swapAt(index, destination)
  }

  private func duplicateRule(at index: Int) {
    guard rules.indices.contains(index) else { return }
    var copy = rules[index]
    copy.id = UUID()
    rules.insert(copy, at: index + 1)
  }
}

private struct RuleDisableMatcherList: View {
  @Binding var matchers: [ManagedRuleDisableMatcher]
  @State private var draggedMatcherID: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Disabled Profile Rules")
        .font(.caption)
        .foregroundStyle(.secondary)

      if matchers.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ForEach(Array(matchers.enumerated()), id: \.element.id) { index, matcher in
          RuleOverlayEditableMatcherRow(
            matcher: Binding(
              get: { matchers[index] },
              set: { matchers[index] = $0 }
            ),
            canMoveUp: index > 0,
            canMoveDown: index < matchers.count - 1,
            onMoveUp: { moveMatcher(from: index, by: -1) },
            onMoveDown: { moveMatcher(from: index, by: 1) },
            onDuplicate: { duplicateMatcher(at: index) },
            onDelete: { matchers.remove(at: index) }
          )
          .onDrag {
            draggedMatcherID = matcher.id
            return NSItemProvider(object: matcher.id.uuidString as NSString)
          }
          .onDrop(
            of: [UTType.text],
            delegate: RuleOverlayMatcherDropDelegate(target: matcher, matchers: $matchers, draggedMatcherID: $draggedMatcherID)
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func moveMatcher(from index: Int, by offset: Int) {
    let destination = index + offset
    guard matchers.indices.contains(index), matchers.indices.contains(destination) else { return }
    matchers.swapAt(index, destination)
  }

  private func duplicateMatcher(at index: Int) {
    guard matchers.indices.contains(index) else { return }
    var copy = matchers[index]
    copy.id = UUID()
    matchers.insert(copy, at: index + 1)
  }
}

private struct RuleOverlayEditableRuleRow: View {
  @Binding var rule: ManagedRuleOverlayRule
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onDuplicate: () -> Void
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.tertiary)
          .help("Drag to reorder")

        Picker("Rule Type", selection: Binding(
          get: { rule.kind },
          set: { kind in
            rule.kind = kind
            if !kind.allowsNoResolve {
              rule.noResolve = false
            }
            if kind == .subRule {
              if SubRuleNetworkCondition(condition: rule.value) == nil {
                rule.value = "NETWORK,tcp"
              }
            } else if rule.value.contains(",") {
              rule.value = ""
            }
          }
        )) {
          ForEach(ManagedRuleOverlayRule.Kind.allCases) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 128)

        if rule.kind == .subRule {
          SubRuleConditionPicker(condition: $rule.value)
            .frame(width: 150)
        } else if rule.kind.requiresValue {
          TextField(LocalizedStringKey(rule.kind.valuePlaceholder), text: $rule.value)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 96)
        }

        TextField(LocalizedStringKey(rule.kind.policyPlaceholder), text: $rule.policy)
          .textFieldStyle(.roundedBorder)
          .frame(width: 92)

        if rule.kind.allowsNoResolve {
          Toggle("No Resolve", isOn: $rule.noResolve)
            .toggleStyle(.checkbox)
            .fixedSize()
        }

        Spacer(minLength: 4)

        RuleOverlayRowButtons(
          canMoveUp: canMoveUp,
          canMoveDown: canMoveDown,
          onMoveUp: onMoveUp,
          onMoveDown: onMoveDown,
          onDuplicate: onDuplicate,
          onDelete: onDelete
        )
      }

      Text(rule.runtimeRule)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(rule.validationError == nil ? Color.secondary : Color.red)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .ruleOverlayListRow()
  }
}

private struct RuleOverlayEditableMatcherRow: View {
  @Binding var matcher: ManagedRuleDisableMatcher
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onDuplicate: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.tertiary)
        .help("Drag to reorder")

      Picker("Match", selection: $matcher.mode) {
        ForEach(RuleDisableMatchMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 92)

      TextField("Rule pattern", text: $matcher.pattern)
        .textFieldStyle(.roundedBorder)

      RuleOverlayRowButtons(
        canMoveUp: canMoveUp,
        canMoveDown: canMoveDown,
        onMoveUp: onMoveUp,
        onMoveDown: onMoveDown,
        onDuplicate: onDuplicate,
        onDelete: onDelete
      )
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .ruleOverlayListRow()
  }
}

private struct RuleOverlayRowButtons: View {
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onDuplicate: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 3) {
      Button(action: onMoveUp) {
        Image(systemName: "arrow.up")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .disabled(!canMoveUp)
      .help("Move up")

      Button(action: onMoveDown) {
        Image(systemName: "arrow.down")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .disabled(!canMoveDown)
      .help("Move down")

      Button(action: onDuplicate) {
        Image(systemName: "plus.square.on.square")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .help("Duplicate")

      Button(action: onDelete) {
        Image(systemName: "trash")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .help("Remove")
    }
  }
}

private struct RuleOverlayRuleDropDelegate: DropDelegate {
  let target: ManagedRuleOverlayRule
  @Binding var rules: [ManagedRuleOverlayRule]
  @Binding var draggedRuleID: UUID?

  func dropEntered(info: DropInfo) {
    guard let draggedRuleID,
          draggedRuleID != target.id,
          let from = rules.firstIndex(where: { $0.id == draggedRuleID }),
          let to = rules.firstIndex(where: { $0.id == target.id })
    else { return }
    rules.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedRuleID = nil
    return true
  }
}

private struct RuleOverlayMatcherDropDelegate: DropDelegate {
  let target: ManagedRuleDisableMatcher
  @Binding var matchers: [ManagedRuleDisableMatcher]
  @Binding var draggedMatcherID: UUID?

  func dropEntered(info: DropInfo) {
    guard let draggedMatcherID,
          draggedMatcherID != target.id,
          let from = matchers.firstIndex(where: { $0.id == draggedMatcherID }),
          let to = matchers.firstIndex(where: { $0.id == target.id })
    else { return }
    matchers.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedMatcherID = nil
    return true
  }
}

private struct RuleOverlayListRowModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    content
      .background(RuleOverlaySurface.row(for: colorScheme), in: shape)
      .overlay {
        shape.strokeBorder(RuleOverlaySurface.border(for: colorScheme).opacity(0.52), lineWidth: 1)
      }
  }
}

private extension View {
  func ruleOverlayListRow() -> some View {
    modifier(RuleOverlayListRowModifier())
  }
}

private enum RuleOverlaySurface {
  static func section(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.primary.opacity(0.035) : Color(nsColor: .controlBackgroundColor)
  }

  static func row(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.primary.opacity(0.045) : Color(nsColor: .textBackgroundColor)
  }

  static func border(for colorScheme: ColorScheme) -> Color {
    Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.32 : 0.50)
  }
}

private struct HelperStatusDetailView: View {
  let detail: TunnelHelperStatusDetail
  let logCount: Int
  let latestExitSummary: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      helperStatusRow("Registered", value: yesNo(detail.registered), positive: detail.registered)
      helperStatusRow("Enabled", value: yesNo(detail.enabled), positive: detail.enabled)
      helperStatusRow(
        "Approval",
        value: detail.requiresApproval ? String(localized: "Required") : String(localized: "Clear"),
        positive: !detail.requiresApproval
      )
      helperStatusRow("Bootstrapped", value: yesNo(detail.bootstrapped), positive: detail.bootstrapped)
      helperStatusRow("Fingerprint", value: fingerprintText, positive: detail.fingerprintMatches == true)
      helperStatusRow(
        "XPC",
        value: detail.xpcReachable ? String(localized: "Reachable") : String(localized: "Unreachable"),
        positive: detail.xpcReachable
      )
      helperStatusRow("Protocol", value: protocolText, positive: detail.protocolCompatible)
      if let helperBuildVersion = detail.helperBuildVersion {
        helperStatusRow("Helper Build", value: helperBuildVersion, positive: detail.protocolCompatible)
      }
      helperStatusRow("Running", value: runningText, positive: detail.running)
      helperStatusRow(
        "Recent Logs",
        value: logCount > 0 ? "\(logCount)" : String(localized: "Empty"),
        positive: logCount > 0
      )
      if let latestExitSummary {
        helperStatusRow("Last Exit", value: latestExitSummary, positive: false)
      }
      Text(detail.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func yesNo(_ value: Bool) -> String {
    value ? String(localized: "Yes") : String(localized: "No")
  }

  private var fingerprintText: String {
    guard detail.fingerprintRecorded else {
      return String(localized: "Not Recorded")
    }
    switch detail.fingerprintMatches {
    case true:
      return String(localized: "Match")
    case false:
      return String(localized: "Mismatch")
    case nil:
      return String(localized: "Unknown")
    }
  }

  private var protocolText: String {
    if let protocolVersion = detail.protocolVersion {
      if detail.migrationRequired {
        return String(format: String(localized: "v%lld Needs Repair"), Int64(protocolVersion))
      }
      return "v\(protocolVersion)"
    }
    return detail.migrationRequired ? String(localized: "Missing") : String(localized: "Unknown")
  }

  private var runningText: String {
    if let pid = detail.pid {
      return String(format: String(localized: "PID %lld"), Int64(pid))
    }
    return yesNo(detail.running)
  }

  private func helperStatusRow(_ title: LocalizedStringResource, value: String, positive: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .foregroundStyle(positive ? Color.green : Color.secondary)
        .multilineTextAlignment(.trailing)
    }
    .font(.callout)
  }
}

private struct SettingsToggleRow: View {
  let title: String
  let description: String?
  @Binding var isOn: Bool

  init(_ title: String, description: String? = nil, isOn: Binding<Bool>) {
    self.title = title
    self.description = description
    _isOn = isOn
  }

  var body: some View {
    SettingsControlRow(title, description: description) {
      Toggle(localizedSettingsText(title), isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel(localizedSettingsText(title))
    }
  }
}

private struct SettingsControlRow<Control: View>: View {
  let title: String
  let description: String?
  let control: Control

  init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.description = description
    self.control = control()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        titleBlock
        Spacer(minLength: 16)
        control
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 8) {
        titleBlock
        control
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(localizedSettingsText(title))
        .foregroundStyle(.primary)
      if let description {
        Text(localizedSettingsText(description))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .layoutPriority(1)
  }
}

private struct UpdateVersionRow<Action: View>: View {
  let title: String
  let description: String
  let version: String
  let action: Action

  init(
    title: String,
    description: String,
    version: String,
    @ViewBuilder action: () -> Action
  ) {
    self.title = title
    self.description = description
    self.version = version
    self.action = action()
  }

  init(
    title: String,
    description: String,
    version: String
  ) where Action == EmptyView {
    self.title = title
    self.description = description
    self.version = version
    action = EmptyView()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        titleBlock
        Spacer(minLength: 16)
        versionLabel
        action
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 8) {
        titleBlock
        HStack(spacing: 10) {
          versionLabel
          action
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(localizedSettingsText(title))
        .foregroundStyle(.primary)
      Text(localizedSettingsText(description))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .layoutPriority(1)
  }

  private var versionLabel: some View {
    Text(version)
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }
}

private struct ExternalControlSettingsRow: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var settings: PersistedSettingsStore
  @State private var isControllerPresented = false
  @State private var isCORSPresented = false
  @State private var draft = ExternalControllerSettings.default
  @State private var addressDraft = ExternalControllerSettings.default.address
  @State private var secretDraft = ""
  @State private var error: String?
  @State private var corsDraft = ExternalControllerCORSSettings.default
  @State private var originDraft = ""
  @State private var corsError: String?
  @State private var suppressControllerPresentation = false
  @State private var controllerHealth = ExternalControlHealthResult.idle
  @State private var dashboardHealth: [ExternalDashboardProfile.ID: ExternalControlHealthResult] = [:]
  @State private var isDashboardProfilesPresented = false
  @State private var dashboardNameDraft = ""
  @State private var dashboardURLDraft = "https://yacd.metacubex.one"
  @State private var dashboardReadOnlyDraft = true
  @State private var dashboardSecretDraft = ""
  @State private var dashboardTrustedForSecretAutofillDraft = false
  @State private var dashboardError: String?
  private let healthChecker = ExternalControlHealthChecker()

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text("External Control")
            .foregroundStyle(.primary)
          corsSettingsButton
        }

        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.leading)
      }
      .layoutPriority(1)

      Spacer(minLength: 16)

      dashboardProfilesButton
      dashboardMenu

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityAddTraits(.isButton)
    .onTapGesture {
      guard !suppressControllerPresentation else {
        suppressControllerPresentation = false
        return
      }
      presentControllerSettings()
    }
    .sheet(isPresented: $isControllerPresented) {
      ExternalControlSettingsSheet(
        draft: $draft,
        addressDraft: $addressDraft,
        secretDraft: $secretDraft,
        error: $error,
        onCancel: {
          isControllerPresented = false
        },
        onSave: save
      )
      .frame(width: 520)
      .padding(24)
    }
  }

  private var dashboardMenu: some View {
    Menu {
      ForEach(settings.externalDashboardProfiles) { profile in
        dashboardProfileMenu(for: profile)
      }
      Divider()
      Button {
        runControllerHealthCheck()
      } label: {
        Label("Health Check", systemImage: "heart.text.square")
      }
      Label(controllerHealth.displayMessage, systemImage: healthSymbol(for: controllerHealth))
    } label: {
      Image(systemName: "safari")
        .frame(width: 22, height: 22)
    }
    .help(controllerHealth.displayMessage)
  }

  @ViewBuilder
  private func dashboardProfileMenu(for profile: ExternalDashboardProfile) -> some View {
    let plan = appModel.externalDashboardOpenPlan(for: profile)
    Menu {
      Button {
        NSWorkspace.shared.open(plan.url)
      } label: {
        Label("Open Dashboard", systemImage: "safari")
      }
      if let secret = plan.secretForManualCopy {
        Button {
          copyToPasteboard(secret)
        } label: {
          Label("Copy API Secret", systemImage: "key")
        }
      }
      Button {
        runDashboardHealthCheck(profile)
      } label: {
        Label("Health Check", systemImage: "heart.text.square")
      }
      if let result = dashboardHealth[profile.id] {
        Divider()
        Label(result.displayMessage, systemImage: healthSymbol(for: result))
      }
    } label: {
      Label(profile.name, systemImage: dashboardProfileSymbol(for: profile, plan: plan))
    }
  }

  private var dashboardProfilesButton: some View {
    Button {
      suppressControllerPresentation = true
      resetDashboardDraft()
      isDashboardProfilesPresented = true
      DispatchQueue.main.async {
        suppressControllerPresentation = false
      }
    } label: {
      Image(systemName: "rectangle.3.group")
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .help("Manage external dashboard profiles")
    .popover(isPresented: $isDashboardProfilesPresented, arrowEdge: .bottom) {
      ExternalDashboardProfilesPopover(
        profiles: settings.externalDashboardProfiles,
        name: $dashboardNameDraft,
        urlString: $dashboardURLDraft,
        readOnly: $dashboardReadOnlyDraft,
        secret: $dashboardSecretDraft,
        trustedForSecretAutofill: $dashboardTrustedForSecretAutofillDraft,
        error: $dashboardError,
        onAdd: saveDashboardProfile,
        onDelete: deleteDashboardProfile
      )
      .frame(width: 540)
      .padding(18)
    }
  }

  private var description: String {
    let controllerSettings = settings.externalControllerSettings
    let state = controllerSettings.enabled ? String(localized: "Enabled") : String(localized: "Disabled")
    return String(
      format: String(localized: "%@ for external web dashboards at %@ with Bearer auth."),
      state,
      controllerSettings.address
    )
  }

  private var corsSettingsButton: some View {
    Button {
      suppressControllerPresentation = true
      syncCORSDraft()
      isCORSPresented = true
      DispatchQueue.main.async {
        suppressControllerPresentation = false
      }
    } label: {
      Image(systemName: "gearshape")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .help("Configure external control CORS")
    .popover(isPresented: $isCORSPresented, arrowEdge: .bottom) {
      ExternalControlCORSSettingsPopover(
        draft: $corsDraft,
        originDraft: $originDraft,
        error: $corsError,
        onCancel: {
          isCORSPresented = false
        },
        onSave: saveCORS
      )
      .frame(width: 520)
      .padding(18)
    }
  }

  private func presentControllerSettings() {
    syncDraft()
    isControllerPresented = true
  }

  private func syncDraft() {
    draft = settings.externalControllerSettings
    addressDraft = draft.address
    secretDraft = draft.normalizedSecret
    error = nil
  }

  private func syncCORSDraft() {
    corsDraft = settings.externalControllerSettings.cors
    corsDraft.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(corsDraft.allowedOrigins)
    originDraft = ""
    corsError = nil
  }

  private func save() {
    guard let parsed = Self.parseAddress(addressDraft) else {
      error = String(localized: "Listen address must use 127.0.0.1:<port>, for example 127.0.0.1:9097.")
      return
    }
    draft.host = parsed.host
    draft.port = parsed.port
    draft.secret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.cors.enabled = draft.enabled
    draft.cors.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(draft.cors.allowedOrigins)
    if let validationError = draft.validationError {
      error = validationError
      return
    }
    guard appModel.updateExternalControllerSettings(draft) else {
      error = appModel.lastError
      return
    }
    isControllerPresented = false
  }

  private func saveCORS() {
    corsDraft.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(corsDraft.allowedOrigins)
    if let validationError = corsDraft.validationError {
      corsError = validationError
      return
    }
    var controllerSettings = settings.externalControllerSettings
    corsDraft.enabled = controllerSettings.enabled
    controllerSettings.cors = corsDraft
    guard appModel.updateExternalControllerSettings(controllerSettings) else {
      corsError = appModel.lastError
      return
    }
    isCORSPresented = false
  }

  private func resetDashboardDraft() {
    dashboardNameDraft = ""
    dashboardURLDraft = "https://yacd.metacubex.one"
    dashboardReadOnlyDraft = true
    dashboardSecretDraft = ""
    dashboardTrustedForSecretAutofillDraft = false
    dashboardError = nil
  }

  private func saveDashboardProfile() {
    let trimmedName = dashboardNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      dashboardError = "Dashboard name cannot be empty."
      return
    }
    guard let url = URL(string: dashboardURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    else {
      dashboardError = "Dashboard URL must start with http or https."
      return
    }
    let profile = ExternalDashboardProfile(
      name: trimmedName,
      url: url,
      readOnly: dashboardReadOnlyDraft,
      trustedForSecretAutofill: !dashboardReadOnlyDraft && dashboardTrustedForSecretAutofillDraft
    )
    let secret = dashboardReadOnlyDraft ? nil : dashboardSecretDraft
    guard appModel.saveExternalDashboardProfile(profile, secret: secret) else {
      dashboardError = appModel.lastError
      return
    }
    resetDashboardDraft()
  }

  private func deleteDashboardProfile(_ profile: ExternalDashboardProfile) {
    appModel.deleteExternalDashboardProfile(profile)
    dashboardHealth[profile.id] = nil
  }

  private func runControllerHealthCheck() {
    controllerHealth = .checking
    let controllerSettings = settings.externalControllerSettings
    Task { @MainActor in
      controllerHealth = await healthChecker.checkController(settings: controllerSettings)
    }
  }

  private func runDashboardHealthCheck(_ profile: ExternalDashboardProfile) {
    dashboardHealth[profile.id] = .checking
    Task { @MainActor in
      dashboardHealth[profile.id] = await healthChecker.checkDashboard(baseURL: profile.url)
    }
  }

  private func healthSymbol(for result: ExternalControlHealthResult) -> String {
    switch result.status {
    case .idle:
      "heart"
    case .checking:
      "arrow.triangle.2.circlepath"
    case .healthy:
      "checkmark.circle.fill"
    case .failed:
      "exclamationmark.triangle.fill"
    }
  }

  private func dashboardProfileSymbol(for profile: ExternalDashboardProfile, plan: ExternalDashboardOpenPlan) -> String {
    switch plan.secretDelivery {
    case .fragment:
      "shield.checkered"
    case .manualCopy:
      "key"
    case .none:
      profile.readOnly ? "eye" : "pencil"
    }
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private static func parseAddress(_ value: String) -> (host: String, port: Int)? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2,
          ExternalControllerSettings.isAllowedControllerHost(parts[0]),
          let port = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      return nil
    }
    return (ExternalControllerSettings.defaultHost, port)
  }
}

private struct ExternalControlCORSSettingsPopover: View {
  @Binding var draft: ExternalControllerCORSSettings
  @Binding var originDraft: String
  @Binding var error: String?

  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("External Control CORS Settings", systemImage: "network")
        .font(.title3.weight(.semibold))

      Toggle("Allow Private Network Access", isOn: $draft.allowPrivateNetwork)
        .toggleStyle(.switch)

      VStack(alignment: .leading, spacing: 8) {
        Text("Allowed Origins")
          .font(.headline)

        VStack(spacing: 8) {
          ForEach(Array(draft.allowedOrigins.enumerated()), id: \.offset) { index, _ in
            HStack(spacing: 8) {
              TextField("https://dashboard.example", text: originBinding(at: index))
                .textFieldStyle(.roundedBorder)
              Button {
                draft.allowedOrigins.remove(at: index)
              } label: {
                Image(systemName: "trash")
                  .frame(width: 22, height: 22)
              }
              .buttonStyle(.borderedProminent)
              .tint(.red)
              .controlSize(.small)
              .help("Remove origin")
            }
          }
        }

        HStack(spacing: 8) {
          TextField("https://dashboard.example", text: $originDraft)
            .textFieldStyle(.roundedBorder)
            .onSubmit(addOrigin)
          Button("Add", action: addOrigin)
            .disabled(originDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        Text("Always includes: \(ExternalControllerCORSSettings.fixedLocalOrigins.joined(separator: ", "))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func originBinding(at index: Int) -> Binding<String> {
    Binding(
      get: {
        guard draft.allowedOrigins.indices.contains(index) else { return "" }
        return draft.allowedOrigins[index]
      },
      set: { value in
        guard draft.allowedOrigins.indices.contains(index) else { return }
        draft.allowedOrigins[index] = value
      }
    )
  }

  private func addOrigin() {
    let trimmed = originDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard ExternalControllerCORSSettings.isValidOrigin(trimmed) else {
      error = ExternalControllerCORSSettings.invalidOriginMessage(trimmed)
      return
    }
    draft.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(draft.allowedOrigins + [trimmed])
    originDraft = ""
    error = nil
  }
}

private struct ExternalControlSettingsSheet: View {
  @Binding var draft: ExternalControllerSettings
  @Binding var addressDraft: String
  @Binding var secretDraft: String
  @Binding var error: String?

  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("External Controller Listen Address", systemImage: "network")
        .font(.title3.weight(.semibold))

      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 14) {
          Text("Enable External Controller")
            .frame(width: 170, alignment: .leading)
          Toggle("Enable External Controller", isOn: $draft.enabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        labeledField("Controller Listen Address") {
          HStack(spacing: 8) {
            TextField("127.0.0.1:9097", text: $addressDraft)
              .textFieldStyle(.roundedBorder)
              .monospacedDigit()
              .disabled(!draft.enabled)
            copyButton(value: addressDraft, isEnabled: draft.enabled, help: "Copy listen address")
          }
        }

        labeledField("API Access Secret") {
          HStack(spacing: 8) {
            TextField("set-your-secret", text: $secretDraft)
              .textFieldStyle(.roundedBorder)
              .disabled(!draft.enabled)
            copyButton(value: secretDraft, isEnabled: draft.enabled, help: "Copy API secret")
          }
        }
      }

      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  @ViewBuilder
  private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Text(localizedSettingsText(title))
        .frame(width: 170, alignment: .leading)
      content()
    }
  }

  private func copyButton(value: String, isEnabled: Bool, help: String) -> some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
    } label: {
      Image(systemName: "doc.on.doc")
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .disabled(!isEnabled || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    .help(help)
  }
}

private func localizedSettingsText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}

private func popoverHeader(_ title: LocalizedStringResource, systemImage: String) -> some View {
  Label {
    Text(title)
  } icon: {
    Image(systemName: systemImage)
  }
  .font(.title3.weight(.semibold))
}

private struct PortControl: View {
  private static let portRange = 1024...65535

  let title: String
  var description: String?
  @Binding var value: Int

  var body: some View {
    SettingsControlRow(title, description: description) {
      NumberStepperField(
        accessibilityLabel: title,
        value: $value,
        range: Self.portRange
      )
    }
  }
}

private struct NumberStepperField: View {
  let accessibilityLabel: String
  @Binding var value: Int
  let range: ClosedRange<Int>
  var step = 1
  var fieldWidth: CGFloat = 82
  @State private var draft = ""

  var body: some View {
    HStack(spacing: 8) {
      TextField("", text: $draft)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: fieldWidth)
        .accessibilityLabel(localizedSettingsText(accessibilityLabel))
        .onSubmit(commitDraft)
        .onChange(of: draft) { _, newValue in
          updateValueIfValid(newValue)
        }
        .onAppear(perform: syncDraft)
        .onChange(of: value) { _, _ in
          syncDraft()
        }

      Stepper(localizedSettingsText(accessibilityLabel), value: clampedValue, in: range, step: step)
        .labelsHidden()
    }
  }

  private var clampedValue: Binding<Int> {
    Binding(
      get: { clamped(value) },
      set: { newValue in value = clamped(newValue) }
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
