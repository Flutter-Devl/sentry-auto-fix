/// CodeGuardian AI - Validation pipeline: quality gates over a project's
/// findings.
///
/// Core pieces:
///  * [parseValidatorConfig]/[loadValidatorConfig] -- parses
///    `codeguardian.yaml` (rule enable/disable, exclude paths, gate
///    thresholds) into a [ValidatorConfig].
///  * [evaluateGates] -- checks a `List<Finding>` against a
///    [ValidatorConfig]'s gates, returning a [GateResult].
///  * [parseBaseline]/[loadBaseline]/[applyBaseline] -- reads
///    `codeguardian-baseline.json` and suppresses pre-existing findings by
///    content hash (see [computeContentHash]).
///  * [validate] -- the full pipeline (rule selection, exclude paths,
///    baseline suppression, then gate evaluation) in one call.
///  * [exitCodeFor] -- maps a [GateResult] to a 0/1 process exit code. Tool
///    errors are thrown as [ConfigParseException]/[BaselineParseException],
///    never encoded in a [GateResult], so they can't be confused with a
///    gate failure -- see `codeguardian_cli`'s `ValidateCommand` for how
///    those map to exit code 2.
library codeguardian_validator;

export 'src/baseline.dart';
export 'src/config_parser.dart';
export 'src/exclude_filter.dart';
export 'src/gate_evaluator.dart';
export 'src/gate_result.dart';
export 'src/validate.dart';
export 'src/validator_config.dart';
