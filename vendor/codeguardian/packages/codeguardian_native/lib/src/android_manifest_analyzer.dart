import 'dart:io';

import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'xml_utils.dart';

/// Parses `android/app/src/main/AndroidManifest.xml` and flags common
/// Android app-hardening gaps:
///
///  * Exported components (`activity`, `activity-alias`, `service`,
///    `receiver`, `provider`) with `android:exported="true"` and no
///    `android:permission` guard.
///  * `android:usesCleartextTraffic="true"` on `<application>`.
///  * `android:debuggable="true"` on `<application>`.
///  * `<application>` missing `android:allowBackup="false"`.
///  * Broad or sensitive `<uses-permission>` entries.
///
/// This is a [ProjectRule]: it needs the project root to locate the
/// manifest, not a single resolved Dart file. Projects with no `android/`
/// directory (or no manifest) are skipped rather than treated as a
/// violation.
class AndroidManifestAnalyzer implements ProjectRule {
  /// Creates the analyzer.
  const AndroidManifestAnalyzer();

  static const _exportableComponentTags = {
    'activity',
    'activity-alias',
    'service',
    'receiver',
    'provider',
  };

  /// Permissions broad or sensitive enough to warrant a second look, even
  /// though many apps have a legitimate need for one or more of them.
  static const _overBroadPermissions = {
    'android.permission.READ_EXTERNAL_STORAGE',
    'android.permission.WRITE_EXTERNAL_STORAGE',
    'android.permission.MANAGE_EXTERNAL_STORAGE',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_BACKGROUND_LOCATION',
    'android.permission.READ_SMS',
    'android.permission.SEND_SMS',
    'android.permission.READ_CONTACTS',
    'android.permission.READ_CALL_LOG',
    'android.permission.CAMERA',
    'android.permission.RECORD_AUDIO',
    'android.permission.SYSTEM_ALERT_WINDOW',
    'android.permission.QUERY_ALL_PACKAGES',
  };

  @override
  String get id => 'android-manifest-security';

  @override
  Future<List<Finding>> check(String projectPath) async {
    final manifestFile = File(
      p.join(
        projectPath,
        'android',
        'app',
        'src',
        'main',
        'AndroidManifest.xml',
      ),
    );
    if (!manifestFile.existsSync()) return const [];

    final content = await manifestFile.readAsString();
    final XmlDocument document;
    try {
      document = XmlDocument.parse(content);
    } on XmlException {
      return const [];
    }

    final lines = content.split('\n');
    final path = manifestFile.path;
    final findings = <Finding>[];

    final manifestElement = document.rootElement;
    final applicationElement =
        firstElementOrNull(manifestElement.findElements('application'));

    if (applicationElement != null) {
      _checkCleartextTraffic(applicationElement, lines, path, findings);
      _checkDebuggable(applicationElement, lines, path, findings);
      _checkAllowBackup(applicationElement, lines, path, findings);
      _checkExportedComponents(applicationElement, lines, path, findings);
    }

    _checkOverBroadPermissions(manifestElement, lines, path, findings);

    return findings;
  }

  void _checkCleartextTraffic(
    XmlElement application,
    List<String> lines,
    String path,
    List<Finding> findings,
  ) {
    if (application.getAttribute('android:usesCleartextTraffic') != 'true') {
      return;
    }

    final line = lineContaining(lines, 'usesCleartextTraffic') ?? 1;
    findings.add(Finding(
      ruleId: 'android-manifest-security',
      category: Category.security,
      severity: Severity.high,
      file: path,
      line: line,
      column: 1,
      message: 'android:usesCleartextTraffic="true" allows the app to send '
          'unencrypted HTTP traffic; remove it (or set it to "false") '
          'unless plaintext traffic is genuinely required for specific '
          'domains via a network security config.',
      snippet: lines[line - 1].trim(),
      cweId: 'CWE-319',
      masvsId: 'MASVS-NETWORK-1',
    ));
  }

  void _checkDebuggable(
    XmlElement application,
    List<String> lines,
    String path,
    List<Finding> findings,
  ) {
    if (application.getAttribute('android:debuggable') != 'true') return;

    final line = lineContaining(lines, 'debuggable') ?? 1;
    findings.add(Finding(
      ruleId: 'android-manifest-security',
      category: Category.security,
      severity: Severity.high,
      file: path,
      line: line,
      column: 1,
      message: 'android:debuggable="true" leaves the app attachable by a '
          'debugger, exposing memory and control flow; this must be false '
          'in release builds (Flutter normally manages this automatically '
          '-- check for a manual override in the manifest).',
      snippet: lines[line - 1].trim(),
      cweId: 'CWE-489',
      masvsId: 'MASVS-RESILIENCE-2',
    ));
  }

  void _checkAllowBackup(
    XmlElement application,
    List<String> lines,
    String path,
    List<Finding> findings,
  ) {
    if (application.getAttribute('android:allowBackup') == 'false') return;

    final line = lineContaining(lines, 'allowBackup') ??
        lineContaining(lines, '<application') ??
        1;
    findings.add(Finding(
      ruleId: 'android-manifest-security',
      category: Category.security,
      severity: Severity.medium,
      file: path,
      line: line,
      column: 1,
      message: 'android:allowBackup is not set to "false", so app data '
          '(databases, shared preferences, files) can be extracted via adb '
          'backup or cloud backup; set android:allowBackup="false" unless '
          'backups are intentionally supported and vetted.',
      snippet: lines[line - 1].trim(),
      cweId: 'CWE-530',
      masvsId: 'MASVS-STORAGE-1',
    ));
  }

  void _checkExportedComponents(
    XmlElement application,
    List<String> lines,
    String path,
    List<Finding> findings,
  ) {
    for (final tag in _exportableComponentTags) {
      for (final component in application.findElements(tag)) {
        if (component.getAttribute('android:exported') != 'true') continue;
        if (component.getAttribute('android:permission') != null) continue;

        final name = component.getAttribute('android:name') ?? '(unnamed)';
        final line =
            lineContaining(lines, name) ?? lineContaining(lines, '<$tag') ?? 1;
        findings.add(Finding(
          ruleId: 'android-manifest-security',
          category: Category.security,
          severity: Severity.high,
          file: path,
          line: line,
          column: 1,
          message: "'$name' ($tag) is exported "
              '(android:exported="true") without an android:permission '
              'guard, so any other app on the device can launch or bind to '
              'it; add a permission or set exported="false" if it is not a '
              'genuine public entry point.',
          snippet: lines[line - 1].trim(),
          cweId: 'CWE-926',
          masvsId: 'MASVS-PLATFORM-2',
        ));
      }
    }
  }

  void _checkOverBroadPermissions(
    XmlElement manifest,
    List<String> lines,
    String path,
    List<Finding> findings,
  ) {
    for (final usesPermission in manifest.findElements('uses-permission')) {
      final name = usesPermission.getAttribute('android:name');
      if (name == null || !_overBroadPermissions.contains(name)) continue;

      final line = lineContaining(lines, name) ?? 1;
      findings.add(Finding(
        ruleId: 'android-manifest-security',
        category: Category.security,
        severity: Severity.medium,
        file: path,
        line: line,
        column: 1,
        message: "'$name' is a broad or sensitive permission; verify it is "
            'genuinely required and consider a narrower alternative (e.g. '
            'the Storage Access Framework instead of broad storage access, '
            'or coarse instead of fine/background location) to reduce the '
            "app's attack surface and privacy footprint.",
        snippet: lines[line - 1].trim(),
        cweId: 'CWE-250',
        masvsId: 'MASVS-PLATFORM-1',
      ));
    }
  }
}
