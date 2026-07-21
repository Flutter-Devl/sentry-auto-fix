// Normal output goes through `print` (captured by the CLI's test harness and
// consistent with the other commands); only hard errors use `stderr`.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:codeguardian_fixer/codeguardian_fixer.dart';
import 'package:codeguardian_reporter/codeguardian_reporter.dart';
import 'package:codeguardian_rules/codeguardian_rules.dart';
import 'package:codeguardian_validator/codeguardian_validator.dart';
import 'package:path/path.dart' as p;

import 'module_discovery.dart';

/// The `improve` command: the full pipeline over a project (or its modules) --
/// analyze, apply deterministic fixes, validate the result against quality
/// gates, and write one end-to-end report.
///
/// Dry-run by default (mirrors [applyFixes]): it reports the fixes it *would*
/// apply and leaves the code untouched. `--apply` writes them, git-checkpointed.
///
/// Exit codes match `validate`: `0` all module gates passed, `1` at least one
/// gate failed, `2` a tool error (bad path/config, or `--apply` outside a git
/// working tree).
class ImproveCommand extends Command<int> {
  /// Creates the command and registers its options.
  ImproveCommand() {
    argParser
      ..addOption('path',
          abbr: 'p', defaultsTo: '.', help: 'Directory of the project to improve.')
      ..addMultiOption('module',
          help: 'Restrict the run to the named module(s). Repeatable. '
              'Omit to process every discovered module.')
      ..addFlag('apply',
          defaultsTo: false,
          help: 'Write fixes to disk (a git checkpoint is created first). '
              'Without this flag the command is a dry run.')
      ..addOption('out',
          defaultsTo: 'codeguardian-report',
          help: 'Directory to write the report into (report.json is always '
              'written; report.html/report.md per --report-format).')
      ..addOption('report-format',
          allowed: const ['html', 'markdown', 'json'],
          defaultsTo: 'html',
          help: 'Human-readable report format to write alongside report.json.')
      ..addOption('config',
          help: 'Validator config file (default: <path>/codeguardian.yaml). '
              'A missing file means no gates.')
      ..addOption('baseline',
          help: 'Baseline file (default: <path>/codeguardian-baseline.json). '
              'A missing file means an empty baseline.')
      ..addOption('max-passes',
          defaultsTo: '10',
          help: 'Max fix/re-analyze passes per run before giving up on '
              'convergence.')
      ..addFlag('dashboard',
          defaultsTo: false,
          help: 'Also write a self-contained dashboard.html into --out (a '
              'dark, interactive findings + AI-fixes view that opens straight '
              'in a browser -- just like report.html).');
  }

  @override
  String get name => 'improve';

  @override
  String get description =>
      'Run the full pipeline over a project: analyze, fix, validate the fixes, '
      'and write an end-to-end report (module-wise for larger projects).';

  @override
  Future<int> run() async {
    final results = argResults!;
    final path = results['path'] as String;
    final apply = results['apply'] as bool;
    final only = results['module'] as List<String>;
    final reportFormat = results['report-format'] as String;

    final maxPasses = int.tryParse(results['max-passes'] as String);
    if (maxPasses == null || maxPasses < 1) {
      stderr.writeln("Invalid --max-passes: '${results['max-passes']}'.");
      return 2;
    }

    final directory = Directory(path);
    if (!directory.existsSync()) {
      stderr.writeln("Path not found: '$path'");
      return 2;
    }
    final projectRoot = p.normalize(directory.absolute.path);

    if (apply && !await _isGitWorkTree(projectRoot)) {
      stderr.writeln(
        'Refusing to --apply: $projectRoot is not inside a git working tree. '
        'Fixes are only applied with a git checkpoint in place. Run '
        '`git init` (and commit) first, or drop --apply for a dry run.',
      );
      return 2;
    }

    final List<Module> modules;
    try {
      modules = discoverModules(projectRoot, only: only);
    } on ArgumentError catch (error) {
      stderr.writeln('codeguardian: ${error.message}');
      return 2;
    }
    final mode = modules.length > 1 ? 'module-wise' : 'whole-project';

    final ValidatorConfig config;
    final Baseline baseline;
    try {
      config = await loadValidatorConfig(
          results['config'] as String? ?? p.join(projectRoot, 'codeguardian.yaml'));
      baseline = await loadBaseline(results['baseline'] as String? ??
          p.join(projectRoot, 'codeguardian-baseline.json'));
    } on ConfigParseException catch (error) {
      stderr.writeln('codeguardian: $error');
      return 2;
    } on BaselineParseException catch (error) {
      stderr.writeln('codeguardian: $error');
      return 2;
    }

    // Analyze the whole project. Without --module, keep every finding (loose
    // files like lib/main.dart included) and group them into modules for the
    // report; with --module, keep only findings inside the selected modules.
    final scopeAll = only.isEmpty;
    final before = _inScope(await _analyze(projectRoot), modules, scopeAll);

    final applied = <Fix>[];
    final failed = <FixFailure>[];
    List<Finding> after;
    List<Fix> proposedOrApplied;

    if (apply) {
      for (var pass = 0; pass < maxPasses; pass++) {
        final current = _inScope(await _analyze(projectRoot), modules, scopeAll);
        final fixes = buildDeterministicFixes(current, projectRoot);
        if (fixes.isEmpty) break;
        final result =
            await applyFixes(fixes, projectPath: projectRoot, apply: true);
        applied.addAll(result.succeeded);
        if (result.succeeded.isEmpty) {
          failed.addAll(result.failed);
          break;
        }
      }
      after = _inScope(await _analyze(projectRoot), modules, scopeAll);
      proposedOrApplied = applied;
    } else {
      proposedOrApplied = buildDeterministicFixes(before, projectRoot);
      after = before;
    }

    final overall =
        validate(findings: after, projectPath: projectRoot, config: config, baseline: baseline);

    final pipeline = _buildPipelineJson(
      projectRoot: projectRoot,
      mode: mode,
      apply: apply,
      modules: modules,
      before: before,
      after: after,
      fixes: proposedOrApplied,
      failed: failed,
      overall: overall.gateResult,
      config: config,
      baseline: baseline,
    );

    _writeReports(results['out'] as String, reportFormat, pipeline);
    _printSummary(pipeline, projectRoot, results['out'] as String, reportFormat);

    final gateExitCode = overall.gateResult.passed ? 0 : 1;

    if (results['dashboard'] as bool) {
      _writeDashboard(
        results['out'] as String,
        projectRoot,
        after,
        proposedOrApplied,
      );
    }

    return gateExitCode;
  }

  /// Writes a self-contained `dashboard.html` (post-improvement findings +
  /// the fixes that were applied/proposed) next to the report in [out].
  void _writeDashboard(
    String out,
    String projectRoot,
    List<Finding> findings,
    List<Fix> fixes,
  ) {
    final dir = Directory(out)..createSync(recursive: true);
    final html = generateDashboardHtml(
      findings.map((f) => _relativizeFinding(f, projectRoot)).toList(),
      fixes: fixes.map((fx) => _fixJson(fx, projectRoot)).toList(),
    );
    final file = File(p.join(dir.path, 'dashboard.html'))
      ..writeAsStringSync(html);
    print('Dashboard:        ${file.path} (open in a browser)');
  }

  RuleRegistry _registry() => RuleRegistry([
        ...qualityRulePack(),
        ...securityRulePack(),
        ...performanceRulePack(),
      ], performanceProjectRulePack());

  Future<List<Finding>> _analyze(String path) async =>
      (await _registry().analyze(path)).findings.toList();

  List<Finding> _inScope(
    List<Finding> findings,
    List<Module> modules,
    bool scopeAll,
  ) {
    if (scopeAll) return findings;
    return findings
        .where((f) => modules.any((m) => _fileInModule(f.file, m)))
        .toList();
  }

  bool _fileInModule(String file, Module module) =>
      p.equals(module.path, file) || p.isWithin(module.path, file);

  Map<String, dynamic> _buildPipelineJson({
    required String projectRoot,
    required String mode,
    required bool apply,
    required List<Module> modules,
    required List<Finding> before,
    required List<Finding> after,
    required List<Fix> fixes,
    required List<FixFailure> failed,
    required GateResult overall,
    required ValidatorConfig config,
    required Baseline baseline,
  }) {
    final moduleJson = <Map<String, dynamic>>[];
    for (final m in modules) {
      final mBefore = before.where((f) => _fileInModule(f.file, m)).toList();
      final mAfter = after.where((f) => _fileInModule(f.file, m)).toList();
      final mFixes = fixes.where((fx) => _fileInModule(fx.file, m)).toList();
      final mFailed =
          failed.where((fl) => _fileInModule(fl.fix.file, m)).toList();
      final mGate = validate(
        findings: mAfter,
        projectPath: projectRoot,
        config: config,
        baseline: baseline,
      ).gateResult;

      moduleJson.add({
        'name': m.name,
        'path': p.relative(m.path, from: projectRoot),
        'before': mBefore.map((f) => _relativizeFinding(f, projectRoot)).toList(),
        'after': mAfter.map((f) => _relativizeFinding(f, projectRoot)).toList(),
        'fixes': mFixes.map((fx) => _fixJson(fx, projectRoot)).toList(),
        'failed': mFailed
            .map((fl) => {
                  'ruleId': fl.fix.ruleId,
                  'file': p.relative(fl.fix.file, from: projectRoot),
                  'reason': fl.reason,
                })
            .toList(),
        'validation': mGate.toJson(),
      });
    }

    // Findings/fixes in files that fall outside every discovered module (e.g.
    // lib/main.dart in feature-folder mode, or test/ files) are grouped under
    // a synthetic "(root)" module so nothing is dropped from the report.
    bool covered(String file) => modules.any((m) => _fileInModule(file, m));
    final lBefore = before.where((f) => !covered(f.file)).toList();
    final lAfter = after.where((f) => !covered(f.file)).toList();
    final lFixes = fixes.where((fx) => !covered(fx.file)).toList();
    final lFailed = failed.where((fl) => !covered(fl.fix.file)).toList();
    if (lBefore.isNotEmpty ||
        lAfter.isNotEmpty ||
        lFixes.isNotEmpty ||
        lFailed.isNotEmpty) {
      moduleJson.add({
        'name': '(root)',
        'path': '.',
        'before': lBefore.map((f) => _relativizeFinding(f, projectRoot)).toList(),
        'after': lAfter.map((f) => _relativizeFinding(f, projectRoot)).toList(),
        'fixes': lFixes.map((fx) => _fixJson(fx, projectRoot)).toList(),
        'failed': lFailed
            .map((fl) => {
                  'ruleId': fl.fix.ruleId,
                  'file': p.relative(fl.fix.file, from: projectRoot),
                  'reason': fl.reason,
                })
            .toList(),
        'validation': validate(
          findings: lAfter,
          projectPath: projectRoot,
          config: config,
          baseline: baseline,
        ).gateResult.toJson(),
      });
    }

    return {
      'project': projectRoot,
      'mode': mode,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'applied': apply,
      'totals': {
        'modules': modules.length,
        'findingsBefore': before.length,
        'findingsAfter': after.length,
        'fixesApplied': apply ? fixes.length : 0,
        'fixesProposed': apply ? 0 : fixes.length,
        'fixesFailed': failed.length,
        'gatesPassed': overall.passed,
        'score': overall.score,
      },
      'modules': moduleJson,
    };
  }

  Map<String, dynamic> _fixJson(Fix fix, String projectRoot) => {
        'ruleId': fix.ruleId,
        'file': p.relative(fix.file, from: projectRoot),
        'confidence': fix.confidence,
        'diff': fix.diff,
      };

  Map<String, dynamic> _relativizeFinding(Finding f, String projectRoot) {
    final json = f.toJson();
    json['file'] = p.relative(f.file, from: projectRoot);
    return json;
  }

  void _writeReports(String out, String format, Map<String, dynamic> pipeline) {
    final outDir = Directory(out)..createSync(recursive: true);
    File(p.join(outDir.path, 'report.json'))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(pipeline));

    switch (format) {
      case 'html':
        File(p.join(outDir.path, 'report.html'))
            .writeAsStringSync(generatePipelineHtmlReport(pipeline));
      case 'markdown':
        File(p.join(outDir.path, 'report.md'))
            .writeAsStringSync(generatePipelineMarkdownReport(pipeline));
      case 'json':
        break; // report.json already written.
    }
  }

  void _printSummary(
    Map<String, dynamic> pipeline,
    String projectRoot,
    String out,
    String format,
  ) {
    final totals = pipeline['totals'] as Map<String, dynamic>;
    final apply = pipeline['applied'] == true;
    print('=== CodeGuardian improve (${pipeline['mode']}) ===');
    print('Project:          $projectRoot');
    print('Modules:          ${totals['modules']}');
    print('Findings before:  ${totals['findingsBefore']}');
    print('Findings after:   ${totals['findingsAfter']}');
    if (apply) {
      print('Fixes applied:    ${totals['fixesApplied']}');
    } else {
      print('Fixes proposed:   ${totals['fixesProposed']} '
          '(dry run -- pass --apply to write)');
    }
    if ((totals['fixesFailed'] as int) > 0) {
      print('Fixes failed:     ${totals['fixesFailed']}');
    }
    print('Score:            ${totals['score']} '
        '(${totals['gatesPassed'] == true ? 'gates passed' : 'gates FAILED'})');
    final ext = format == 'markdown' ? 'report.md' : format == 'json' ? 'report.json' : 'report.html';
    print('Report:           ${p.join(out, ext)} (+ ${p.join(out, 'report.json')})');
  }

  Future<bool> _isGitWorkTree(String path) async {
    try {
      final result = await Process.run(
        'git',
        ['rev-parse', '--is-inside-work-tree'],
        workingDirectory: path,
      );
      return result.exitCode == 0 &&
          (result.stdout as String).trim() == 'true';
    } on ProcessException {
      return false;
    }
  }
}
