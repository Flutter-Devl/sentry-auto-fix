import 'package:codeguardian_core/codeguardian_core.dart';

import '../fix.dart';
import '../fix_utils.dart';

/// Builds a [Fix] for a subset of `android-manifest-security` findings (see
/// `AndroidManifestAnalyzer` in `codeguardian_native`), dispatching on
/// [Finding.cweId] since the rule shares one `ruleId` across several
/// distinct checks:
///
///  * `CWE-319` (`usesCleartextTraffic="true"`) -- removes the attribute.
///  * `CWE-489` (`debuggable="true"`) -- removes the attribute.
///  * `CWE-530` (missing `allowBackup="false"`) -- flips `allowBackup` to
///    `"false"` if present, or inserts the attribute if absent.
///
/// Returns `null` for the rule's other two checks (`CWE-926` exported
/// component without a permission guard, `CWE-250` broad/sensitive
/// permission): removing a component's exported flag or a permission could
/// break real functionality, so those need a human decision, not a
/// mechanical fix.
Fix? buildAndroidManifestSecurityFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'android-manifest-security') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildAndroidManifestSecurityFix only handles '
          'android-manifest-security findings',
    );
  }

  switch (finding.cweId) {
    case 'CWE-319':
      return _removeAttribute(
        finding,
        projectPath,
        'android:usesCleartextTraffic="true"',
      );
    case 'CWE-489':
      return _removeAttribute(finding, projectPath, 'android:debuggable="true"');
    case 'CWE-530':
      return _fixAllowBackup(finding, projectPath);
    default:
      return null;
  }
}

Fix _removeAttribute(
  Finding finding,
  String projectPath,
  String attributeText,
) {
  return buildFixFromLineTransform(
    ruleId: finding.ruleId,
    file: finding.file,
    projectPath: projectPath,
    transform: (oldLines) {
      final newLines = List<String>.of(oldLines);
      final index = finding.line - 1;
      final cleaned = newLines[index].replaceAll(attributeText, '').trimRight();
      if (cleaned.trim().isEmpty) {
        newLines.removeAt(index);
      } else {
        newLines[index] = cleaned;
      }
      return newLines;
    },
  );
}

Fix _fixAllowBackup(Finding finding, String projectPath) {
  return buildFixFromLineTransform(
    ruleId: finding.ruleId,
    file: finding.file,
    projectPath: projectPath,
    transform: (oldLines) {
      final newLines = List<String>.of(oldLines);
      final index = finding.line - 1;
      final line = newLines[index];

      if (line.contains('android:allowBackup="true"')) {
        newLines[index] =
            line.replaceAll('android:allowBackup="true"', 'android:allowBackup="false"');
      } else {
        // The attribute was absent entirely, so the reported line is the
        // <application ...> tag itself; insert the attribute right after it.
        final indent = '${leadingWhitespaceOf(line)}    ';
        newLines.insert(index + 1, '${indent}android:allowBackup="false"');
      }
      return newLines;
    },
  );
}
