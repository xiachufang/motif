import Cocoa
import FlutterMacOS
import XCTest
@testable import Motif

class RunnerTests: XCTestCase {
  func testPermissionParsing() {
    for permission in MacosPermissionKind.allCases {
      let parsed = MacosPermissionsController.permission(from: [
        "permission": permission.rawValue,
      ])
      XCTAssertEqual(parsed, permission)
    }
    XCTAssertNil(MacosPermissionsController.permission(from: nil))
    XCTAssertNil(MacosPermissionsController.permission(from: [
      "permission": "unknown",
    ]))
  }

  func testPermissionStatusesHaveStableShape() {
    let statuses = MacosPermissionsController.statuses()
    XCTAssertEqual(Set(statuses.keys), Set(MacosPermissionKind.allCases.map(\.rawValue)))
    XCTAssertEqual(
      statuses[MacosPermissionKind.fullDiskAccess.rawValue],
      MacosPermissionState.managedExternally.rawValue)
    for value in statuses.values {
      XCTAssertNotNil(MacosPermissionState(rawValue: value))
    }
  }

  func testModernPermissionSettingsURLs() {
    XCTAssertEqual(
      MacosPermissionsController.settingsURL(for: .fullDiskAccess, modern: true)?.absoluteString,
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
    XCTAssertEqual(
      MacosPermissionsController.settingsURL(for: .screenRecording, modern: true)?.absoluteString,
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
    XCTAssertEqual(
      MacosPermissionsController.settingsURL(for: .accessibility, modern: true)?.absoluteString,
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
    XCTAssertEqual(
      MacosPermissionsController.settingsURL(for: .automation, modern: true)?.absoluteString,
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")
  }

  func testLegacyPermissionSettingsURLs() {
    XCTAssertEqual(
      MacosPermissionsController.settingsURL(for: .fullDiskAccess, modern: false)?.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    XCTAssertEqual(
      MacosPermissionsController.privacySettingsURL(modern: false)?.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy")
  }
}
