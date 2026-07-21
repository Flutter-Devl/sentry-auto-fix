import 'package:codeguardian_core/codeguardian_core.dart';

import '../fix.dart';
import '../fix_utils.dart';

/// Builds a [Fix] that deletes an unused import line.
///
/// A minimal, concrete fix generator demonstrating the fix infrastructure
/// end to end: given an `unused-import` [Finding] (see `UnusedImportRule` in
/// `codeguardian_rules`), it removes exactly the reported line.
///
/// [projectPath] is the project root the resulting [Fix.diff] will later be
/// applied against; the diff's headers use [finding]'s file relative to it.
Fix buildUnusedImportFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'unused-import') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildUnusedImportFix only handles unused-import findings',
    );
  }

  return buildFixFromLineTransform(
    ruleId: finding.ruleId,
    file: finding.file,
    projectPath: projectPath,
    transform: (oldLines) => List<String>.of(oldLines)
      ..removeAt(finding.line - 1),
  );
}
