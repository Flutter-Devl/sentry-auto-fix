import 'package:analyzer/dart/analysis/results.dart';

import 'models/finding.dart';

/// A single static-analysis rule.
///
/// Implementations inspect a fully resolved compilation unit — which carries
/// complete type information via [ResolvedUnitResult] — and report any problems
/// as [Finding]s. Rules must be pure and side-effect free: given the same unit
/// they must return the same findings, and they must not mutate shared state.
abstract interface class CodeGuardianRule {
  /// A stable, unique identifier for the rule (e.g. `hardcoded_secret`).
  ///
  /// This is copied into the [Finding.ruleId] of every finding the rule emits.
  String get id;

  /// Inspects a resolved [unit] and returns the findings it contains.
  ///
  /// Returns an empty list when the rule finds nothing. Implementations should
  /// never return `null`.
  List<Finding> check(ResolvedUnitResult unit);
}
