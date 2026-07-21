import 'package:codeguardian_core/codeguardian_core.dart';

import '../fix.dart';
import '../fix_utils.dart';

/// Builds a [Fix] that replaces the first `http://` on the flagged line
/// with `https://`, for a finding from `InsecureHttpUrlRule` (see
/// `codeguardian_rules`).
Fix buildInsecureHttpUrlFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'insecure-http-url') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildInsecureHttpUrlFix only handles insecure-http-url findings',
    );
  }

  return buildFixFromLineTransform(
    ruleId: finding.ruleId,
    file: finding.file,
    projectPath: projectPath,
    transform: (oldLines) {
      final newLines = List<String>.of(oldLines);
      newLines[finding.line - 1] =
          newLines[finding.line - 1].replaceFirst('http://', 'https://');
      return newLines;
    },
  );
}
