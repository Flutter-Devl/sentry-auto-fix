import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:codeguardian_rules/codeguardian_rules.dart';
import 'package:codeguardian_validator/codeguardian_validator.dart';
import 'package:path/path.dart' as p;

/// The `validate` command: runs the rule packs over a project, applies
/// `codeguardian.yaml` configuration and `codeguardian-baseline.json`
/// suppression, and exits according to whether the configured gates
/// passed.
///
/// Exit codes:
///  * `0` -- every gate passed.
///  * `1` -- at least one gate failed. A normal, expected outcome -- look
///    at the printed findings/failures.
///  * `2` -- the tool itself couldn't complete (bad path, malformed config
///    or baseline file, or an unexpected internal error). This is never
///    conflated with `1`: a gate failure and a tool error are different
///    kinds of "not green," and only one of them means "look at your
///    code." See [ConfigParseException]/[BaselineParseException] handling
///    below, and the top-level catch-all in `codeguardian_cli.dart` that
///    maps any other unexpected exception to `2` as well.
class ValidateCommand extends Command<int> {
  /// Creates the command and registers its options.
  ValidateCommand() {
    argParser
      ..addOption(
        'path',
        abbr: 'p',
        defaultsTo: '.',
        help: 'Directory of the project to validate.',
      )
      ..addOption(
        'config',
        help: 'Path to the config file (default: <path>/codeguardian.yaml). '
            "A missing file is fine -- it's the same as no restrictions and "
            'no gates.',
      )
      ..addOption(
        'baseline',
        help: 'Path to the baseline file (default: '
            '<path>/codeguardian-baseline.json). A missing file is fine -- '
            "it's the same as an empty baseline.",
      )
      ..addOption(
        'format',
        abbr: 'f',
        allowed: const ['json'],
        defaultsTo: 'json',
        help: 'Output format. Only "json" is supported currently.',
      );
  }

  @override
  String get name => 'validate';

  @override
  String get description =>
      'Evaluate quality gates for a project. Exits 0 (pass), 1 (gate '
      'failure), or 2 (tool error).';

  @override
  Future<int> run() async {
    final results = argResults!;
    final path = results['path'] as String;
    final format = results['format'] as String;

    if (format != 'json') {
      stderr.writeln(
        "Unsupported --format '$format'. Only 'json' is supported right now.",
      );
      return 2;
    }

    final directory = Directory(path);
    if (!directory.existsSync()) {
      stderr.writeln("Path not found: '$path'");
      return 2;
    }
    final projectPath = directory.absolute.path;

    final ValidatorConfig config;
    final Baseline baseline;
    try {
      final configPath =
          results['config'] as String? ?? p.join(projectPath, 'codeguardian.yaml');
      config = await loadValidatorConfig(configPath);

      final baselinePath = results['baseline'] as String? ??
          p.join(projectPath, 'codeguardian-baseline.json');
      baseline = await loadBaseline(baselinePath);
    } on ConfigParseException catch (error) {
      stderr.writeln('codeguardian: $error');
      return 2;
    } on BaselineParseException catch (error) {
      stderr.writeln('codeguardian: $error');
      return 2;
    }

    final registry = RuleRegistry([
      ...qualityRulePack(),
      ...securityRulePack(),
      ...performanceRulePack(),
    ], performanceProjectRulePack());

    final analysis = await registry.analyze(projectPath);

    final outcome = validate(
      findings: analysis.findings,
      projectPath: projectPath,
      config: config,
      baseline: baseline,
    );

    final output = {
      'passed': outcome.gateResult.passed,
      'score': outcome.gateResult.score,
      'totalFindings': outcome.gateResult.totalFindings,
      'countsBySeverity': outcome.gateResult.countsBySeverity,
      'suppressedByBaseline': outcome.suppressedByBaseline.length,
      'failures': outcome.gateResult.failures.map((f) => f.toJson()).toList(),
      'findings': outcome.findings.map((f) => f.toJson()).toList(),
    };
    // ignore: avoid_print
    print(const JsonEncoder.withIndent('  ').convert(output));

    return exitCodeFor(outcome.gateResult);
  }
}
