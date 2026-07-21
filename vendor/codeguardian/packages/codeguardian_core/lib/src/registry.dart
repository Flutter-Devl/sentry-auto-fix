import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart' hide AnalysisResult;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;

import 'analysis_result.dart';
import 'models/finding.dart';
import 'project_rule.dart';
import 'rule.dart';

/// Holds a set of [CodeGuardianRule]s and [ProjectRule]s and runs them over a
/// project.
///
/// The registry is the analysis-engine foundation: it uses the Dart analyzer's
/// [AnalysisContextCollection] to resolve every Dart file in a project with
/// full type information, hands each resolved unit to every registered
/// [CodeGuardianRule], then runs every registered [ProjectRule] once against
/// the project root, and aggregates the resulting [Finding]s.
///
/// The engine works with zero registered rules — it will resolve the project
/// and return an empty finding list — which makes it useful as a pure
/// resolution check as well as a rule runner.
class RuleRegistry {
  /// Creates a registry, optionally seeded with an initial set of [rules]
  /// and [projectRules].
  RuleRegistry([
    Iterable<CodeGuardianRule> rules = const [],
    Iterable<ProjectRule> projectRules = const [],
  ])  : _rules = List.of(rules),
        _projectRules = List.of(projectRules);

  final List<CodeGuardianRule> _rules;
  final List<ProjectRule> _projectRules;

  /// The per-file rules currently registered, in registration order.
  List<CodeGuardianRule> get rules => List.unmodifiable(_rules);

  /// The project-level rules currently registered, in registration order.
  List<ProjectRule> get projectRules => List.unmodifiable(_projectRules);

  /// Registers [rule] so it participates in subsequent [analyze] calls.
  void register(CodeGuardianRule rule) => _rules.add(rule);

  /// Registers every rule in [rules].
  void registerAll(Iterable<CodeGuardianRule> rules) => _rules.addAll(rules);

  /// Registers [rule] so it participates in subsequent [analyze] calls.
  void registerProjectRule(ProjectRule rule) => _projectRules.add(rule);

  /// Registers every rule in [rules].
  void registerAllProjectRules(Iterable<ProjectRule> rules) =>
      _projectRules.addAll(rules);

  /// Resolves every Dart file under [projectPath] and runs all rules.
  ///
  /// [projectPath] may be relative; it is normalized to an absolute path, as
  /// required by [AnalysisContextCollection]. Files that fail to resolve (for
  /// example, ones with syntax errors that prevent resolution) are skipped
  /// rather than aborting the whole run.
  ///
  /// Returns an [AnalysisResult] containing the aggregated findings and the
  /// list of files that were successfully resolved.
  Future<AnalysisResult> analyze(String projectPath) async {
    final rootPath = p.normalize(p.absolute(projectPath));

    final collection = AnalysisContextCollection(
      includedPaths: [rootPath],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
    );

    final findings = <Finding>[];
    final resolvedFiles = <String>[];

    for (final context in collection.contexts) {
      // analyzedFiles() yields absolute, normalized paths for this context.
      for (final filePath in context.contextRoot.analyzedFiles()) {
        if (!filePath.endsWith('.dart')) continue;

        final result =
            await context.currentSession.getResolvedUnit(filePath);
        if (result is! ResolvedUnitResult) continue;

        resolvedFiles.add(filePath);

        for (final rule in _rules) {
          findings.addAll(rule.check(result));
        }
      }
    }

    for (final projectRule in _projectRules) {
      findings.addAll(await projectRule.check(rootPath));
    }

    return AnalysisResult(
      findings: List.unmodifiable(findings),
      resolvedFiles: List.unmodifiable(resolvedFiles),
    );
  }
}
