import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:meta/meta.dart';

import 'baseline.dart';
import 'exclude_filter.dart';
import 'gate_evaluator.dart';
import 'gate_result.dart';
import 'validator_config.dart';

/// The full outcome of running [validate]: the findings that survived
/// filtering, the ones a baseline suppressed, and the resulting gate
/// evaluation.
@immutable
class ValidationOutcome {
  /// Creates a validation outcome.
  const ValidationOutcome({
    required this.findings,
    required this.suppressedByBaseline,
    required this.gateResult,
  });

  /// Findings after rule-selection, exclude-path, and baseline filtering --
  /// exactly what [gateResult] was computed from.
  final List<Finding> findings;

  /// Findings that were dropped because they matched a [Baseline] entry.
  final List<Finding> suppressedByBaseline;

  /// The gate evaluation over [findings].
  final GateResult gateResult;
}

/// Runs the full validation pipeline: filters [findings] by [config]'s rule
/// selection and exclude paths, suppresses anything in [baseline], then
/// evaluates [config]'s gates over what's left.
///
/// [projectPath] is the project root findings' file paths and [baseline]
/// entries are resolved relative to.
ValidationOutcome validate({
  required List<Finding> findings,
  required String projectPath,
  required ValidatorConfig config,
  Baseline baseline = Baseline.empty,
}) {
  var filtered =
      findings.where((finding) => config.rules.isEnabled(finding.ruleId)).toList();
  filtered = filterExcluded(filtered, config.excludePaths, projectPath: projectPath);

  final (:remaining, :suppressed) =
      applyBaseline(filtered, baseline, projectPath: projectPath);

  return ValidationOutcome(
    findings: remaining,
    suppressedByBaseline: suppressed,
    gateResult: evaluateGates(remaining, config),
  );
}
