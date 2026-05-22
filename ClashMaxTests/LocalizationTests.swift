import Foundation
import XCTest
@testable import ClashMax

final class LocalizationTests: XCTestCase {
  func testStatusSectionAppearsAfterHome() {
    XCTAssertEqual(Array(AppSection.allCases.prefix(2)), [.home, .status])
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
    XCTAssertEqual(zhBundle.localizedString(forKey: "Settings", value: nil, table: nil), "设置")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Language", value: nil, table: nil), "语言")
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
    XCTAssertEqual(zhBundle.localizedString(forKey: "Enabled, no rules", value: nil, table: nil), "已启用，无规则")
    XCTAssertEqual(zhBundle.localizedString(forKey: "%lld managed rules", value: nil, table: nil), "%lld 条托管规则")
    XCTAssertEqual(zhBundle.localizedString(forKey: "China Optimized", value: nil, table: nil), "中国优化")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Profile DNS", value: nil, table: nil), "配置 DNS")
    XCTAssertEqual(zhBundle.localizedString(forKey: "Global Secure", value: nil, table: nil), "全局安全")
  }
}
