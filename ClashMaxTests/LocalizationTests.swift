import Foundation
import XCTest
@testable import ClashMax

final class LocalizationTests: XCTestCase {
  func testStatusSectionAppearsAfterHome() {
    XCTAssertEqual(Array(AppSection.allCases.prefix(2)), [.home, .status])
  }

  func testRoutingSectionAppearsBetweenConnectionsAndRules() {
    guard let connectionsIndex = AppSection.allCases.firstIndex(of: .connections),
          let routingIndex = AppSection.allCases.firstIndex(of: .routing),
          let rulesIndex = AppSection.allCases.firstIndex(of: .rules)
    else {
      return XCTFail("Expected Connections, Routing, and Rules sections")
    }

    XCTAssertEqual(routingIndex, AppSection.allCases.index(after: connectionsIndex))
    XCTAssertEqual(rulesIndex, AppSection.allCases.index(after: routingIndex))
  }

  func testAppBundleDeclaresEnglishAndSimplifiedChineseLocalizations() throws {
    let bundle = try XCTUnwrap(Bundle(identifier: AppConstants.bundleIdentifier))

    XCTAssertEqual(bundle.developmentLocalization, "en")
    XCTAssertTrue(bundle.localizations.contains("en"))
    XCTAssertTrue(bundle.localizations.contains("zh-Hans"))
  }

  func testSimplifiedChineseStringCatalogProvidesRepresentativeSettingsKeys() throws {
    let bundle = try XCTUnwrap(Bundle(identifier: AppConstants.bundleIdentifier))
    let enPath = try XCTUnwrap(bundle.path(forResource: "en", ofType: "lproj"))
    let zhPath = try XCTUnwrap(bundle.path(forResource: "zh-Hans", ofType: "lproj"))
    let enBundle = try XCTUnwrap(Bundle(path: enPath))
    let zhBundle = try XCTUnwrap(Bundle(path: zhPath))

    XCTAssertEqual(enBundle.localizedString(forKey: "Settings", value: nil, table: nil), "Settings")
    XCTAssertEqual(enBundle.localizedString(forKey: "Expanded", value: nil, table: nil), "Expanded")
    XCTAssertEqual(enBundle.localizedString(forKey: "Collapsed", value: nil, table: nil), "Collapsed")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Settings", value: nil, table: nil), "设置")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Language", value: nil, table: nil), "语言")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Expanded", value: nil, table: nil), "已展开")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Collapsed", value: nil, table: nil), "已折叠")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Fake IP DNS", value: nil, table: nil), "Fake IP DNS")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Fake IP Range", value: nil, table: nil), "Fake IP 范围")
    XCTAssertEqual(zhBundle.localizedString(forKey: "System DNS Override", value: nil, table: nil), "覆盖系统 DNS")
    XCTAssertEqual(zhBundle.localizedString(forKey: "System DNS Servers", value: nil, table: nil), "系统 DNS 服务器")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Repair DNS", value: nil, table: nil), "修复 DNS")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Repair Routing", value: nil, table: nil), "修复路由")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Repair TUN routing", value: nil, table: nil), "修复 TUN 路由")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Last Exit", value: nil, table: nil), "最近退出")
    XCTAssertEqual(zhBundle.localizedString(forKey: "NE Diagnostics", value: nil, table: nil), "NE 诊断")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Copy Diagnostics", value: nil, table: nil), "复制诊断")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Effective DNS", value: nil, table: nil), "生效 DNS")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Rule Overlay", value: nil, table: nil), "规则覆盖")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Profile Rule Overlay", value: nil, table: nil), "配置规则覆盖")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Runtime Merge YAML", value: nil, table: nil), "运行时合并 YAML")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Result", value: nil, table: nil), "结果")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Detail", value: nil, table: nil), "详情")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Default Subscription Interval", value: nil, table: nil), "默认订阅间隔")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Fallback interval used when a subscription does not publish profile-update-interval.", value: nil, table: nil), "当订阅未发布 profile-update-interval 时使用的回退间隔。")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Background Check Interval", value: nil, table: nil), "后台检查间隔")
    XCTAssertEqual(zhBundle.localizedString(forKey: "How often ClashMax wakes to check whether any subscription is due.", value: nil, table: nil), "ClashMax 唤醒检查订阅是否到期的频率。")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Retry Backoff Cap", value: nil, table: nil), "重试退避上限")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Maximum delay after repeated subscription update failures.", value: nil, table: nil), "多次订阅更新失败后的最大延迟。")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Notify Update Failures", value: nil, table: nil), "通知更新失败")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Show a macOS notification when automatic subscription refresh fails.", value: nil, table: nil), "自动订阅刷新失败时显示 macOS 通知。")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Disable Profile Rule", value: nil, table: nil), "停用配置规则")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Disabled Profile Rules", value: nil, table: nil), "已停用的配置规则")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Enabled, no rules", value: nil, table: nil), "已启用，无规则")
    XCTAssertEqual(zhBundle.localizedString(forKey: "%lld managed rules", value: nil, table: nil), "%lld 条托管规则")
    XCTAssertEqual(zhBundle.localizedString(forKey: "China Optimized", value: nil, table: nil), "中国优化")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Profile DNS", value: nil, table: nil), "配置 DNS")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Global Secure", value: nil, table: nil), "全局安全")
  }

  func testSimplifiedChineseStringCatalogProvidesMenuBarKeys() throws {
    let bundle = try XCTUnwrap(Bundle(identifier: AppConstants.bundleIdentifier))
    let zhPath = try XCTUnwrap(bundle.path(forResource: "zh-Hans", ofType: "lproj"))
    let zhBundle = try XCTUnwrap(Bundle(path: zhPath))

    XCTAssertEqual(zhBundle.localizedString(forKey: "Start Core", value: nil, table: nil), "启动核心")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Stop Core", value: nil, table: nil), "停止核心")
    XCTAssertEqual(zhBundle.localizedString(forKey: "No Profile", value: nil, table: nil), "无配置")
    XCTAssertEqual(zhBundle.localizedString(forKey: "No Core", value: nil, table: nil), "无核心")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Running TUN", value: nil, table: nil), "TUN 运行中")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Running NE", value: nil, table: nil), "NE 运行中")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Preview", value: nil, table: nil), "预览")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Crashed", value: nil, table: nil), "已崩溃")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Needs Setup", value: nil, table: nil), "需要设置")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Traffic", value: nil, table: nil), "流量")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Waiting for runtime data", value: nil, table: nil), "等待运行时数据")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Run Mode", value: nil, table: nil), "运行模式")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Proxy Routing", value: nil, table: nil), "代理路由")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Enable System Proxy", value: nil, table: nil), "启用系统代理")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Disable System Proxy", value: nil, table: nil), "停用系统代理")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Update Subscription", value: nil, table: nil), "更新订阅")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Open Main Window", value: nil, table: nil), "打开主窗口")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Quit", value: nil, table: nil), "退出")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Core is starting.", value: nil, table: nil), "核心正在启动。")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Preview runtime is active.", value: nil, table: nil), "预览运行时正在运行。")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Select a profile to start ClashMax.", value: nil, table: nil), "选择配置后即可启动 ClashMax。")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Bundled Mihomo core is unavailable.", value: nil, table: nil), "内置 Mihomo 核心不可用。")
    XCTAssertEqual(zhBundle.localizedString(forKey: "System Proxy requires System Proxy routing.", value: nil, table: nil), "系统代理需要切换到系统代理路由。")

    let ownerFormat = zhBundle.localizedString(forKey: "Owner: %@", value: nil, table: nil)
    XCTAssertEqual(String(format: ownerFormat, "用户模式"), "归属：用户模式")
  }
}
