import 'package:meta/meta.dart';

import 'models/finding.dart';

/// The outcome of a single [RuleRegistry] run over a project.
///
/// Besides the aggregated [findings], it reports how many Dart files were
/// successfully resolved, which lets callers (and tests) confirm the engine
/// actually loaded and type-resolved the project rather than silently skipping
/// it.
@immutable
class AnalysisResult {
  /// Creates an analysis result.
  const AnalysisResult({
    required this.findings,
    required this.resolvedFiles,
  });

  /// Every finding produced by every rule, across every resolved file.
  final List<Finding> findings;

  /// Absolute paths of the Dart files that were successfully resolved.
  final List<String> resolvedFiles;

  /// The number of Dart files that were successfully resolved.
  int get resolvedFileCount => resolvedFiles.length;

  /// Whether any rule reported a problem.
  bool get hasFindings => findings.isNotEmpty;
}
