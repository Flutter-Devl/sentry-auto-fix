import 'package:codeguardian_core/codeguardian_core.dart';

import '../fix.dart';
import '../fix_utils.dart';

/// Builds a [Fix] that inserts the `const` keyword right before an
/// instantiation flagged by `MissingConstConstructorRule` (see
/// `codeguardian_rules`).
///
/// The rule only fires when it has already verified the invoked constructor
/// is `const` and every argument is constant-eligible, so inserting `const`
/// at [finding]'s reported column is always valid.
Fix buildMissingConstConstructorFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'missing-const-constructor') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildMissingConstConstructorFix only handles '
          'missing-const-constructor findings',
    );
  }

  return buildFixFromLineTransform(
    ruleId: finding.ruleId,
    file: finding.file,
    projectPath: projectPath,
    transform: (oldLines) {
      final newLines = List<String>.of(oldLines);
      final line = newLines[finding.line - 1];
      final column = finding.column - 1;
      newLines[finding.line - 1] =
          '${line.substring(0, column)}const ${line.substring(column)}';
      return newLines;
    },
  );
}
