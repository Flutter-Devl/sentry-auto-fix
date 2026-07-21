import 'package:meta/meta.dart';

/// A single gate that failed, with enough detail to explain why.
@immutable
class GateFailure {
  /// Creates a gate failure.
  const GateFailure({
    required this.gate,
    required this.threshold,
    required this.actual,
    required this.message,
  });

  /// The gate's name, e.g. `max_high` or `min_score` (matches the
  /// `codeguardian.yaml` key).
  final String gate;

  /// The configured threshold.
  final num threshold;

  /// The actual observed value that violated [threshold].
  final num actual;

  /// A human-readable explanation, e.g. `"max_high exceeded: 6 > 5"`.
  final String message;

  /// A JSON-serializable representation of this failure.
  Map<String, dynamic> toJson() => {
        'gate': gate,
        'threshold': threshold,
        'actual': actual,
        'message': message,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GateFailure &&
          runtimeType == other.runtimeType &&
          gate == other.gate &&
          threshold == other.threshold &&
          actual == other.actual &&
          message == other.message;

  @override
  int get hashCode => Object.hash(gate, threshold, actual, message);

  @override
  String toString() => 'GateFailure($gate: $message)';
}

/// The outcome of evaluating a [ValidatorConfig]'s gates against a set of
/// findings.
@immutable
class GateResult {
  /// Creates a gate result.
  const GateResult({
    required this.passed,
    required this.failures,
    required this.totalFindings,
    required this.countsBySeverity,
    required this.score,
  });

  /// Whether every configured gate passed. `true` whenever no gates are
  /// configured, regardless of how many findings there are -- a gate that
  /// was never set can't be violated.
  final bool passed;

  /// Every gate that failed. Empty when [passed] is `true`.
  final List<GateFailure> failures;

  /// How many findings were evaluated (after rule/exclude/baseline
  /// filtering).
  final int totalFindings;

  /// Finding count per severity label (e.g. `'critical'`, `'high'`).
  final Map<String, int> countsBySeverity;

  /// The computed score (see `computeScore`).
  final num score;

  /// A JSON-serializable representation of this result.
  Map<String, dynamic> toJson() => {
        'passed': passed,
        'failures': failures.map((f) => f.toJson()).toList(),
        'totalFindings': totalFindings,
        'countsBySeverity': countsBySeverity,
        'score': score,
      };

  @override
  String toString() =>
      'GateResult(passed: $passed, failures: $failures, '
      'totalFindings: $totalFindings, score: $score)';
}
