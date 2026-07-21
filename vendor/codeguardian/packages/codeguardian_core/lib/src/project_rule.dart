import 'models/finding.dart';

/// A rule that inspects the whole project rather than a single resolved
/// Dart file -- for example, comparing the dependencies declared in
/// `pubspec.yaml` against what's actually imported anywhere under `lib/`.
///
/// Unlike [CodeGuardianRule] (which [RuleRegistry] runs once per resolved
/// file), a [ProjectRule] runs exactly once per [RuleRegistry.analyze] call,
/// after every file has been resolved, and is given the project's root
/// directory to inspect however it needs to: reading `pubspec.yaml` or
/// `pubspec.lock`, walking the file tree, etc. Implementations must still be
/// pure and side-effect free: given the same [projectPath] they must return
/// the same findings, and they must not mutate shared state.
abstract interface class ProjectRule {
  /// A stable, unique identifier for the rule (e.g. `unused-plugin-dependency`).
  ///
  /// This is copied into the [Finding.ruleId] of every finding the rule emits.
  String get id;

  /// Inspects the project rooted at [projectPath] and returns the findings
  /// it contains.
  ///
  /// [projectPath] is an absolute, normalized directory path. Returns an
  /// empty list when the rule finds nothing. Implementations should never
  /// return `null`.
  Future<List<Finding>> check(String projectPath);
}
