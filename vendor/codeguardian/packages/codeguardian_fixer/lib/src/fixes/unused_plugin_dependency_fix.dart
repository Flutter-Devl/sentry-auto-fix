import 'package:codeguardian_core/codeguardian_core.dart';

import '../fix.dart';
import '../fix_utils.dart';

/// Builds a [Fix] that deletes an unused dependency's declaration line from
/// `pubspec.yaml`, for a finding from `UnusedPluginDependencyRule` (see
/// `codeguardian_rules`).
Fix buildUnusedPluginDependencyFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'unused-plugin-dependency') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildUnusedPluginDependencyFix only handles '
          'unused-plugin-dependency findings',
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
