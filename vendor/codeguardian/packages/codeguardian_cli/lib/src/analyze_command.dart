// Normal status output goes through `print` (captured by the CLI's test
// harness); only hard errors use `stderr`.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:codeguardian_fixer/codeguardian_fixer.dart';
import 'package:codeguardian_reporter/codeguardian_reporter.dart';
import 'package:codeguardian_rules/codeguardian_rules.dart';
import 'package:path/path.dart' as p;

/// Output formats supported by `--format`.
const _supportedFormats = ['json', 'html', 'markdown', 'sarif'];

/// The `analyze` command: runs the quality, security, and performance rule
/// packs over a project and reports the resulting findings.
///
/// By default it prints the findings to stdout in the requested `--format`.
/// It can also:
///  * `--apply` deterministic fixes first (git-checkpointed) and report the
///    resulting, post-fix state;
///  * `--out <dir>` write `report.json` (+ a human report per `--format`) to
///    disk; and
///  * `--dashboard` publish the report into the Flutter dashboard app and
///    launch it, so one command produces both the report and the dashboard.
class AnalyzeCommand extends Command<int> {
  /// Creates the command and registers its options.
  AnalyzeCommand() {
    argParser
      ..addOption(
        'path',
        abbr: 'p',
        defaultsTo: '.',
        help: 'Directory of the project to analyze.',
      )
      ..addOption(
        'severity',
        abbr: 's',
        allowed: Severity.values.map((severity) => severity.label),
        help: 'Only report findings at or above this severity.',
      )
      ..addOption(
        'format',
        abbr: 'f',
        allowed: _supportedFormats,
        defaultsTo: 'json',
        help: 'Output format: "json" (raw findings array), "html" (a '
            'self-contained interactive report), "markdown" (PR-comment '
            'friendly summary + collapsible per-category sections), or '
            '"sarif" (SARIF 2.1.0, for GitHub code scanning and similar '
            'CI dashboards).',
      )
      ..addFlag(
        'diff-only',
        defaultsTo: false,
        help: 'Only analyze files changed relative to the base branch. '
            'Accepted but not yet implemented -- the full project is '
            'analyzed regardless.',
      )
      ..addFlag(
        'apply',
        defaultsTo: false,
        help: 'Apply deterministic fixes before reporting (a git checkpoint '
            'is created first). The report reflects the post-fix state.',
      )
      ..addOption(
        'out',
        help: 'Directory to write the report into (report.json is always '
            'written; a human report matching --format is written too). '
            'Without this, and without --dashboard, the report is printed to '
            'stdout as before.',
      )
      ..addFlag(
        'dashboard',
        defaultsTo: false,
        help: 'Also write a self-contained dashboard.html into the output '
            'directory (a dark, interactive findings + AI-fixes view that '
            'opens straight in a browser -- just like report.html).',
      );
  }

  @override
  String get name => 'analyze';

  @override
  String get description =>
      'Analyze a project with the quality, security, and performance rule '
      'packs; print or write findings (JSON, HTML, Markdown, SARIF), '
      'optionally applying fixes and opening the dashboard.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final path = results['path'] as String;
    final format = results['format'] as String;
    final severityArg = results['severity'] as String?;
    final apply = results['apply'] as bool;
    final out = results['out'] as String?;
    final toDashboard = results['dashboard'] as bool;

    // --diff-only is parsed and accepted for forward compatibility, but the
    // diff-scoped analysis it implies isn't implemented yet; every run
    // currently analyzes the full project at [path].

    final directory = Directory(path);
    if (!directory.existsSync()) {
      stderr.writeln("Path not found: '$path'");
      return 66;
    }
    final projectRoot = p.normalize(directory.absolute.path);

    if (apply) {
      if (!await _isGitWorkTree(projectRoot)) {
        stderr.writeln(
          'Refusing to --apply: $projectRoot is not inside a git working '
          'tree. Fixes are only applied with a git checkpoint in place. Run '
          '`git init` (and commit) first, or drop --apply.',
        );
        return 2;
      }
      await _applyFixes(projectRoot);
    }

    final minSeverity = severityArg == null
        ? null
        : Severity.values.firstWhere((s) => s.label == severityArg);

    final result = await _registry().analyze(projectRoot);
    final findings = minSeverity == null
        ? result.findings.toList()
        : result.findings
            .where((f) => f.severity.index >= minSeverity.index)
            .toList();

    final findingsJson = const JsonEncoder.withIndent('  ')
        .convert(findings.map((f) => f.toJson()).toList());
    final humanOutput = switch (format) {
      'html' => generateHtmlReportFromFindings(findings),
      'markdown' => generateMarkdownReportFromFindings(findings),
      'sarif' => generateSarifReportFromFindings(findings),
      _ => findingsJson,
    };

    // Backwards-compatible default: no --out and no --dashboard -> print the
    // report to stdout exactly as before.
    if (out == null && !toDashboard) {
      print(humanOutput);
      return 0;
    }

    print('Analyzed $projectRoot: ${findings.length} finding(s)'
        '${apply ? ' (after applying fixes)' : ''}.');

    // Where the artifacts go: the given --out, or a default dir so
    // --dashboard alone still lands somewhere predictable in the project.
    final outDir = out ?? 'codeguardian-report';

    if (out != null) {
      _writeReportFiles(out, format, findingsJson, humanOutput);
    }

    if (toDashboard) {
      final fixes = buildDeterministicFixes(findings, projectRoot);
      _writeDashboard(outDir, projectRoot, findings, fixes);
    }

    return 0;
  }

  RuleRegistry _registry() => RuleRegistry([
        ...qualityRulePack(),
        ...securityRulePack(),
        ...performanceRulePack(),
      ], performanceProjectRulePack());

  /// Applies deterministic fixes over [projectRoot], re-analyzing between
  /// passes until nothing new can be fixed (or a small pass cap is hit), so
  /// fixes that unblock other fixes still get applied.
  Future<void> _applyFixes(String projectRoot) async {
    const maxPasses = 10;
    for (var pass = 0; pass < maxPasses; pass++) {
      final current = (await _registry().analyze(projectRoot)).findings.toList();
      final fixes = buildDeterministicFixes(current, projectRoot);
      if (fixes.isEmpty) break;
      final applied =
          await applyFixes(fixes, projectPath: projectRoot, apply: true);
      if (applied.succeeded.isEmpty) break;
    }
  }

  void _writeReportFiles(
    String out,
    String format,
    String findingsJson,
    String humanOutput,
  ) {
    final outDir = Directory(out)..createSync(recursive: true);
    File(p.join(outDir.path, 'report.json')).writeAsStringSync(findingsJson);

    final ext = switch (format) {
      'html' => 'report.html',
      'markdown' => 'report.md',
      'sarif' => 'report.sarif',
      _ => null, // json already written as report.json
    };
    if (ext != null) {
      File(p.join(outDir.path, ext)).writeAsStringSync(humanOutput);
      print('Report written to ${p.join(out, 'report.json')} '
          '(+ ${p.join(out, ext)}).');
    } else {
      print('Report written to ${p.join(out, 'report.json')}.');
    }
  }

  void _writeDashboard(
    String outDir,
    String projectRoot,
    List<Finding> findings,
    List<Fix> fixes,
  ) {
    final dir = Directory(outDir)..createSync(recursive: true);
    final html = generateDashboardHtml(
      findings.map((f) => _relativizeFinding(f, projectRoot)).toList(),
      fixes: fixes.map((fx) => _relativizeFix(fx, projectRoot)).toList(),
    );
    final file = File(p.join(dir.path, 'dashboard.html'))
      ..writeAsStringSync(html);
    print('Dashboard written to ${file.path} '
        '(open it in a browser -- no server needed).');
  }

  /// A finding as JSON with its `file` made relative to [root], for tidier
  /// display in the dashboard.
  Map<String, dynamic> _relativizeFinding(Finding f, String root) {
    final json = f.toJson();
    json['file'] = p.relative(f.file, from: root);
    return json;
  }

  Map<String, dynamic> _relativizeFix(Fix fx, String root) => {
        'ruleId': fx.ruleId,
        'file': p.relative(fx.file, from: root),
        'diff': fx.diff,
        'confidence': fx.confidence,
      };

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
