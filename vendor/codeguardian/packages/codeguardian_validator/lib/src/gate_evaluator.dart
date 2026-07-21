import 'package:codeguardian_core/codeguardian_core.dart';

import 'gate_result.dart';
import 'validator_config.dart';

/// Per-severity penalty weights [computeScore] subtracts from a starting
/// score of 100.
///
/// This is a deliberately simple, documented formula -- not a research-grade
/// severity model -- chosen so `min_score` gates are easy to reason about
/// and test: a project with no findings scores 100; each critical finding
/// costs 25 points, each high 10, each medium 4, each low 1, and info
/// findings are free. The score never goes below 0.
const Map<Severity, num> scoreWeights = {
  Severity.critical: 25,
  Severity.high: 10,
  Severity.medium: 4,
  Severity.low: 1,
  Severity.info: 0,
};

/// Computes a project's quality score from its findings (see
/// [scoreWeights] for the formula). Always in the range `[0, 100]`.
num computeScore(List<Finding> findings) {
  var penalty = 0.0;
  for (final finding in findings) {
    penalty += scoreWeights[finding.severity] ?? 0;
  }
  final score = 100 - penalty;
  return score < 0 ? 0 : score;
}

/// Evaluates [config]'s gates against [findings], returning whether every
/// gate passed and, if not, which ones failed and why.
///
/// [findings] should already have rule-selection, exclude-path, and
/// baseline filtering applied (see `validate` for the full pipeline) --
/// this function only enforces thresholds against whatever list it's given.
GateResult evaluateGates(List<Finding> findings, ValidatorConfig config) {
  final countsBySeverity = <String, int>{
    for (final severity in Severity.values) severity.label: 0,
  };
  for (final finding in findings) {
    final label = finding.severity.label;
    countsBySeverity[label] = (countsBySeverity[label] ?? 0) + 1;
  }

  final score = computeScore(findings);
  final gates = config.gates;
  final failures = <GateFailure>[];

  void checkMax(String name, int? threshold, int actual) {
    if (threshold == null) return;
    if (actual > threshold) {
      failures.add(GateFailure(
        gate: name,
        threshold: threshold,
        actual: actual,
        message: '$name exceeded: $actual > $threshold',
      ));
    }
  }

  checkMax(
    'max_critical',
    gates.maxCritical,
    countsBySeverity[Severity.critical.label] ?? 0,
  );
  checkMax('max_high', gates.maxHigh, countsBySeverity[Severity.high.label] ?? 0);
  checkMax(
    'max_medium',
    gates.maxMedium,
    countsBySeverity[Severity.medium.label] ?? 0,
  );
  checkMax('max_low', gates.maxLow, countsBySeverity[Severity.low.label] ?? 0);
  checkMax('max_total', gates.maxTotal, findings.length);

  final minScore = gates.minScore;
  if (minScore != null && score < minScore) {
    failures.add(GateFailure(
      gate: 'min_score',
      threshold: minScore,
      actual: score,
      message: 'min_score not met: $score < $minScore',
    ));
  }

  return GateResult(
    passed: failures.isEmpty,
    failures: failures,
    totalFindings: findings.length,
    countsBySeverity: countsBySeverity,
    score: score,
  );
}

/// Maps a [GateResult] to a process exit code: `0` if it passed, `1` if it
/// failed.
///
/// Tool errors (malformed config/baseline, missing paths, unexpected
/// exceptions, ...) are deliberately **not** representable by a
/// [GateResult] -- they're thrown as exceptions instead, precisely so they
/// can never be coerced into this 0/1 mapping. Callers should let those
/// exceptions propagate and map them to a distinct exit code (2) themselves;
/// see `codeguardian_cli`'s `ValidateCommand`.
int exitCodeFor(GateResult result) => result.passed ? 0 : 1;
