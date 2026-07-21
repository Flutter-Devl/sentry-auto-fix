import 'package:codeguardian_core/codeguardian_core.dart';

import '../fix.dart';
import '../fix_utils.dart';

/// Builds a [Fix] that inserts an `if (!mounted) return;` guard right
/// before the statement flagged by `MissingMountedCheckRule` (see
/// `codeguardian_rules`), matching the flagged line's indentation.
Fix buildMissingMountedCheckFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'missing-mounted-check') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildMissingMountedCheckFix only handles missing-mounted-check '
          'findings',
    );
  }

  return buildFixFromLineTransform(
    ruleId: finding.ruleId,
    file: finding.file,
    projectPath: projectPath,
    transform: (oldLines) {
      final newLines = List<String>.of(oldLines);
      final index = finding.line - 1;
      final indent = leadingWhitespaceOf(newLines[index]);
      newLines.insert(index, '${indent}if (!mounted) return;');
      return newLines;
    },
  );
}
