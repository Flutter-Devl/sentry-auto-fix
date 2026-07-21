import 'package:meta/meta.dart';

/// Which rules a project wants to run, by id.
///
/// A rule id is enabled when: [enabled] is unset (meaning "everything"), or
/// the id appears in [enabled] (allow-list mode) -- **and**, in either case,
/// the id does not appear in [disabled] (a deny-list that always wins).
@immutable
class RuleSelection {
  /// Creates a rule selection.
  const RuleSelection({this.enabled, this.disabled = const []});

  /// The complete allow-list of rule ids to run, or `null` to allow every
  /// rule (subject to [disabled]).
  final List<String>? enabled;

  /// Rule ids to always exclude, even if present in [enabled].
  final List<String> disabled;

  /// Whether [ruleId] should run under this selection.
  bool isEnabled(String ruleId) {
    if (disabled.contains(ruleId)) return false;
    final allowList = enabled;
    if (allowList != null && !allowList.contains(ruleId)) return false;
    return true;
  }

  @override
  String toString() => 'RuleSelection(enabled: $enabled, disabled: $disabled)';
}

/// Thresholds a set of findings is checked against.
///
/// Every field is optional; a `null` threshold means that gate isn't
/// enforced. All `max*` gates use "at most N" semantics: a finding count
/// exactly equal to the threshold passes, one more than the threshold fails.
@immutable
class GateConfig {
  /// Creates a gate configuration. Every threshold defaults to unset (not
  /// enforced).
  const GateConfig({
    this.maxCritical,
    this.maxHigh,
    this.maxMedium,
    this.maxLow,
    this.maxTotal,
    this.minScore,
  });

  /// Maximum allowed count of `Severity.critical` findings.
  final int? maxCritical;

  /// Maximum allowed count of `Severity.high` findings.
  final int? maxHigh;

  /// Maximum allowed count of `Severity.medium` findings.
  final int? maxMedium;

  /// Maximum allowed count of `Severity.low` findings.
  final int? maxLow;

  /// Maximum allowed total finding count, across all severities.
  final int? maxTotal;

  /// Minimum required score (see `computeScore`).
  final num? minScore;

  @override
  String toString() => 'GateConfig(maxCritical: $maxCritical, '
      'maxHigh: $maxHigh, maxMedium: $maxMedium, maxLow: $maxLow, '
      'maxTotal: $maxTotal, minScore: $minScore)';
}

/// Parsed `codeguardian.yaml` configuration.
@immutable
class ValidatorConfig {
  /// Creates a config. Defaults to no rule restrictions, no excluded paths,
  /// and no gates enforced.
  const ValidatorConfig({
    this.rules = const RuleSelection(),
    this.excludePaths = const [],
    this.gates = const GateConfig(),
  });

  /// Which rules are enabled/disabled.
  final RuleSelection rules;

  /// Glob patterns (relative to the project root) whose matching files are
  /// excluded from findings entirely.
  final List<String> excludePaths;

  /// Thresholds findings are checked against.
  final GateConfig gates;
}
