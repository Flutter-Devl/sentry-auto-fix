import 'dart:io';

import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'xml_utils.dart';

/// Parses `ios/Runner/Info.plist` and flags common iOS app-hardening gaps:
///
///  * `NSAppTransportSecurity` arbitrary-loads exceptions (app-wide or
///    per-domain).
///  * Sensitive `NS*UsageDescription` keys that are present but empty, or
///    implied by a declared `UIBackgroundModes` entry but absent entirely.
///  * Custom URL scheme (`CFBundleURLTypes`) declarations using a common,
///    easily-collided name.
///
/// This is a [ProjectRule]: it needs the project root to locate the plist,
/// not a single resolved Dart file. Projects with no `ios/` directory (or no
/// `Info.plist`) are skipped rather than treated as a violation.
///
/// Known limitation: whether a usage-description key is *needed* in the
/// first place depends on which sensitive APIs the app's code actually
/// calls, which a plist alone can't tell you -- only two self-contained
/// signals are checked: an empty description for a key that's already
/// present, and a declared background mode whose required key is missing
/// entirely.
class IOSPlistAnalyzer implements ProjectRule {
  /// Creates the analyzer.
  const IOSPlistAnalyzer();

  static const _sensitiveUsageDescriptionKeys = {
    'NSCameraUsageDescription',
    'NSMicrophoneUsageDescription',
    'NSPhotoLibraryUsageDescription',
    'NSPhotoLibraryAddUsageDescription',
    'NSLocationWhenInUseUsageDescription',
    'NSLocationAlwaysAndWhenInUseUsageDescription',
    'NSLocationAlwaysUsageDescription',
    'NSContactsUsageDescription',
    'NSCalendarsUsageDescription',
    'NSRemindersUsageDescription',
    'NSBluetoothAlwaysUsageDescription',
    'NSBluetoothPeripheralUsageDescription',
    'NSFaceIDUsageDescription',
    'NSMotionUsageDescription',
    'NSSpeechRecognitionUsageDescription',
    'NSHealthShareUsageDescription',
    'NSHealthUpdateUsageDescription',
  };

  /// Background modes that require a corresponding usage-description key.
  static const _backgroundModeRequiredKeys = {
    'location': [
      'NSLocationAlwaysAndWhenInUseUsageDescription',
      'NSLocationAlwaysUsageDescription',
    ],
    'bluetooth-central': ['NSBluetoothAlwaysUsageDescription'],
    'bluetooth-peripheral': [
      'NSBluetoothPeripheralUsageDescription',
      'NSBluetoothAlwaysUsageDescription',
    ],
  };

  static const _genericUrlSchemes = {
    'http',
    'https',
    'ftp',
    'file',
    'ws',
    'wss',
    'oauth',
    'auth',
    'callback',
    'redirect',
    'app',
    'test',
  };

  @override
  String get id => 'ios-plist-security';

  @override
  Future<List<Finding>> check(String projectPath) async {
    final plistFile =
        File(p.join(projectPath, 'ios', 'Runner', 'Info.plist'));
    if (!plistFile.existsSync()) return const [];

    final content = await plistFile.readAsString();
    final XmlDocument document;
    try {
      document = XmlDocument.parse(content);
    } on XmlException {
      return const [];
    }

    final rootDict = firstElementOrNull(
      document.rootElement.childElements.where((e) => e.name.local == 'dict'),
    );
    if (rootDict == null) return const [];

    final root = _dictEntries(rootDict);
    final lines = content.split('\n');
    final path = plistFile.path;
    final findings = <Finding>[];

    _checkAppTransportSecurity(root, lines, path, findings);
    _checkUsageDescriptions(root, lines, path, findings);
    _checkUrlSchemes(root, lines, path, findings);

    return findings;
  }

  void _checkAppTransportSecurity(
    Map<String, XmlElement> root,
    List<String> lines,
    String path,
    List<Finding> findings,
  ) {
    final ats = root['NSAppTransportSecurity'];
    if (ats == null || ats.name.local != 'dict') return;
    final atsEntries = _dictEntries(ats);

    final arbitraryLoads = atsEntries['NSAllowsArbitraryLoads'];
    if (arbitraryLoads != null && arbitraryLoads.name.local == 'true') {
      final line = lineContaining(lines, 'NSAllowsArbitraryLoads') ?? 1;
      findings.add(Finding(
        ruleId: 'ios-plist-security',
        category: Category.security,
        severity: Severity.high,
        file: path,
        line: line,
        column: 1,
        message: 'NSAppTransportSecurity.NSAllowsArbitraryLoads is true, '
            'which disables App Transport Security app-wide and allows '
            'plaintext HTTP connections to any host; scope exceptions to '
            'specific domains via NSExceptionDomains instead, or remove '
            'this override.',
        snippet: lines[line - 1].trim(),
        cweId: 'CWE-319',
        masvsId: 'MASVS-NETWORK-1',
      ));
    }

    final exceptionDomains = atsEntries['NSExceptionDomains'];
    if (exceptionDomains == null || exceptionDomains.name.local != 'dict') {
      return;
    }
    final domains = _dictEntries(exceptionDomains);
    for (final domain in domains.entries) {
      if (domain.value.name.local != 'dict') continue;
      final domainSettings = _dictEntries(domain.value);
      final insecureHttp =
          domainSettings['NSExceptionAllowsInsecureHTTPLoads'];
      if (insecureHttp == null || insecureHttp.name.local != 'true') continue;

      final line =
          lineContaining(lines, 'NSExceptionAllowsInsecureHTTPLoads') ?? 1;
      findings.add(Finding(
        ruleId: 'ios-plist-security',
        category: Category.security,
        severity: Severity.high,
        file: path,
        line: line,
        column: 1,
        message: 'NSExceptionDomains.${domain.key}'
            '.NSExceptionAllowsInsecureHTTPLoads is true, allowing '
            'plaintext HTTP to ${domain.key}; use HTTPS unless this domain '
            'genuinely cannot support it.',
        snippet: lines[line - 1].trim(),
        cweId: 'CWE-319',
        masvsId: 'MASVS-NETWORK-1',
      ));
    }
  }

  void _checkUsageDescriptions(
    Map<String, XmlElement> root,
    List<String> lines,
    String path,
    List<Finding> findings,
  ) {
    for (final key in _sensitiveUsageDescriptionKeys) {
      final element = root[key];
      if (element == null || element.name.local != 'string') continue;
      if (element.innerText.trim().isNotEmpty) continue;

      final line = lineContaining(lines, key) ?? 1;
      findings.add(Finding(
        ruleId: 'ios-plist-security',
        category: Category.privacy,
        severity: Severity.medium,
        file: path,
        line: line,
        column: 1,
        message: "'$key' is present but empty; App Store review requires "
            'a non-empty, user-facing explanation of why this permission '
            'is needed.',
        snippet: lines[line - 1].trim(),
        masvsId: 'MASVS-PRIVACY-1',
      ));
    }

    final backgroundModesElement = root['UIBackgroundModes'];
    final modes = <String>{};
    if (backgroundModesElement != null &&
        backgroundModesElement.name.local == 'array') {
      for (final child in backgroundModesElement.childElements) {
        if (child.name.local == 'string') modes.add(child.innerText);
      }
    }

    for (final mode in modes) {
      final requiredKeys = _backgroundModeRequiredKeys[mode];
      if (requiredKeys == null) continue;
      if (requiredKeys.any(root.containsKey)) continue;

      final line = lineContaining(lines, mode) ?? 1;
      findings.add(Finding(
        ruleId: 'ios-plist-security',
        category: Category.privacy,
        severity: Severity.medium,
        file: path,
        line: line,
        column: 1,
        message: "UIBackgroundModes declares '$mode' but none of "
            '${requiredKeys.join(' / ')} is present; add the required '
            'usage description or the background mode will silently not '
            'work (and App Store review will reject the build).',
        snippet: lines[line - 1].trim(),
        masvsId: 'MASVS-PRIVACY-1',
      ));
    }
  }

  void _checkUrlSchemes(
    Map<String, XmlElement> root,
    List<String> lines,
    String path,
    List<Finding> findings,
  ) {
    final urlTypes = root['CFBundleURLTypes'];
    if (urlTypes == null || urlTypes.name.local != 'array') return;

    for (final urlTypeDict in urlTypes.childElements) {
      if (urlTypeDict.name.local != 'dict') continue;
      final entries = _dictEntries(urlTypeDict);
      final schemesElement = entries['CFBundleURLSchemes'];
      if (schemesElement == null || schemesElement.name.local != 'array') {
        continue;
      }

      for (final schemeElement in schemesElement.childElements) {
        if (schemeElement.name.local != 'string') continue;
        final scheme = schemeElement.innerText;
        if (!_genericUrlSchemes.contains(scheme.toLowerCase())) continue;

        final line = lineContaining(lines, scheme) ?? 1;
        findings.add(Finding(
          ruleId: 'ios-plist-security',
          category: Category.security,
          severity: Severity.medium,
          file: path,
          line: line,
          column: 1,
          message: "Custom URL scheme '$scheme' is a common, generic name "
              'that another app could also register, letting it intercept '
              "links intended for this app; use a unique, reverse-DNS-style "
              "scheme (e.g. 'com.yourcompany.yourapp') instead.",
          snippet: lines[line - 1].trim(),
          cweId: 'CWE-939',
          masvsId: 'MASVS-PLATFORM-3',
        ));
      }
    }
  }

  /// Converts a plist `<dict>` element into a map from each `<key>`'s text
  /// to its following value element.
  Map<String, XmlElement> _dictEntries(XmlElement dict) {
    final entries = <String, XmlElement>{};
    final children = dict.childElements.toList();
    var i = 0;
    while (i < children.length - 1) {
      final child = children[i];
      if (child.name.local == 'key') {
        entries[child.innerText] = children[i + 1];
        i += 2;
      } else {
        i += 1;
      }
    }
    return entries;
  }
}
