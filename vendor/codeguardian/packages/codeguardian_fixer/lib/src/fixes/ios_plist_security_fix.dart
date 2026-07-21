import 'package:codeguardian_core/codeguardian_core.dart';

import '../fix.dart';
import '../fix_utils.dart';

/// Builds a [Fix] for the `ios-plist-security` App Transport Security
/// findings (see `IOSPlistAnalyzer` in `codeguardian_native`): both the
/// app-wide `NSAllowsArbitraryLoads` and the per-domain
/// `NSExceptionAllowsInsecureHTTPLoads` checks share `cweId: 'CWE-319'` and
/// the same plist shape (a `<key>...</key>` line immediately followed by a
/// `<true/>` value), so one transform handles both: flip the nearby
/// `<true/>` to `<false/>`.
///
/// Returns `null` for the rule's other two checks (empty usage-description
/// string, generic/collidable custom URL scheme): both need a human to
/// decide on replacement text (what to say to the user, what scheme name to
/// pick), which isn't a mechanical fix.
Fix? buildIosPlistSecurityFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'ios-plist-security') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildIosPlistSecurityFix only handles ios-plist-security findings',
    );
  }
  if (finding.cweId != 'CWE-319') return null;

  return buildFixFromLineTransform(
    ruleId: finding.ruleId,
    file: finding.file,
    projectPath: projectPath,
    transform: (oldLines) {
      final newLines = List<String>.of(oldLines);
      final searchEnd = (finding.line + 1).clamp(0, newLines.length);
      for (var i = finding.line - 1; i < searchEnd; i++) {
        if (newLines[i].contains('<true/>')) {
          newLines[i] = newLines[i].replaceFirst('<true/>', '<false/>');
          break;
        }
      }
      return newLines;
    },
  );
}
