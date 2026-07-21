// Normal output goes through `print` (captured by the CLI's test harness and
// consistent with the other commands); only hard errors use `stderr`.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:codeguardian_ai/codeguardian_ai.dart';
import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:codeguardian_fixer/codeguardian_fixer.dart';
import 'package:codeguardian_reporter/codeguardian_reporter.dart';
import 'package:codeguardian_rules/codeguardian_rules.dart';
import 'package:path/path.dart' as p;

/// The `refactor` command: finds refactoring opportunities with the refactor
/// rule pack, asks the configured AI provider to rewrite each affected file,
/// applies the results as git-checkpointed fixes, and writes an end-to-end
/// report (`report.json` plus `report.html`/`report.md` per `--report-format`).
///
/// Dry-run by default (mirrors [applyFixes]'s own default): without `--apply`
/// it leaves the *source* untouched and reports what it would change. The
/// report itself is always written (into `--out`), on dry runs and applies
/// alike, exactly as `improve` does.
class RefactorCommand extends Command<int> {
  /// Creates the command and registers its options.
  ///
  /// [provider] overrides the AI provider that would otherwise be built from
  /// the project's `codeguardian-ai-config.json`; tests inject a fake here so
  /// they never hit the network.
  RefactorCommand({AiProvider? provider}) : _providerOverride = provider {
    argParser
      ..addOption(
        'path',
        abbr: 'p',
        defaultsTo: '.',
        help: 'Directory of the project to refactor.',
      )
      ..addFlag(
        'apply',
        defaultsTo: false,
        help: 'Write the refactors to disk (a git checkpoint is created '
            'first). Without this flag, the command is a dry run: it reports '
            'what it would change without modifying any source files (the '
            'report is still written).',
      )
      ..addOption(
        'min-confidence',
        defaultsTo: '0.7',
        help: 'Only apply a refactor whose AI confidence is at or above this '
            'threshold (0.0-1.0).',
      )
      ..addOption(
        'out',
        defaultsTo: 'codeguardian-report',
        help: 'Directory to write the report into (report.json is always '
            'written; report.html/report.md per --report-format).',
      )
      ..addOption(
        'report-format',
        allowed: const ['html', 'markdown', 'json'],
        defaultsTo: 'html',
        help: 'Human-readable report format to write alongside report.json.',
      );
  }

  final AiProvider? _providerOverride;

  @override
  String get name => 'refactor';

  @override
  String get description =>
      'Refactor a project with AI-assisted rewrites: move business logic out '
      'of widgets, reduce duplication, and improve widget composition, then '
      'write a report of what changed.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final path = results['path'] as String;
    final apply = results['apply'] as bool;
    final out = results['out'] as String;
    final reportFormat = results['report-format'] as String;

    final minConfidence = double.tryParse(results['min-confidence'] as String);
    if (minConfidence == null || minConfidence < 0.0 || minConfidence > 1.0) {
      stderr.writeln(
        "Invalid --min-confidence: '${results['min-confidence']}'. "
        'Expected a number between 0.0 and 1.0.',
      );
      return 64;
    }

    final directory = Directory(path);
    if (!directory.existsSync()) {
      stderr.writeln("Path not found: '$path'");
      return 66;
    }
    final projectRoot = p.normalize(p.absolute(path));

    final provider = _providerOverride ??
        createAiProvider(
          readAiConfig(File(p.join(projectRoot, aiConfigFileName))),
        );
    if (provider is NoOpAiProvider) {
      print(
        'No AI provider is configured, so there is nothing to refactor '
        'offline.\nRun `codeguardian ai configure` and set the API-key '
        'environment variable it names, then try again.',
      );
      return 0;
    }

    final registry = RuleRegistry(refactorRulePack(), const []);
    final analysis = await registry.analyze(projectRoot);
    if (analysis.findings.isEmpty) {
      print('No refactoring opportunities found.');
      return 0;
    }

    final byFile = <String, List<Finding>>{};
    for (final finding in analysis.findings) {
      byFile.putIfAbsent(finding.file, () => []).add(finding);
    }

    final fixes = <Fix>[];
    final skipped = <String>[];
    for (final entry in byFile.entries) {
      final file = entry.key;
      final findings = entry.value;
      final relative = p.relative(file, from: projectRoot);
      final content = File(file).readAsStringSync();

      // Secret-safety gate: a refactor rewrites the whole file and we then
      // write it back, so if redaction would alter what we send to the model,
      // its rewrite could carry `[REDACTED]` placeholders straight over real
      // secrets on disk. Refuse to auto-refactor such a file.
      if (redactSecrets(content) != content) {
        skipped.add('$relative (skipped: contains a hardcoded secret; '
            'refactoring it could overwrite the secret with a redaction '
            'placeholder)');
        continue;
      }

      final suggestion = await provider.suggestRefactor(findings, content);
      if (suggestion.suggestedCode == null) {
        skipped.add('$relative (skipped: AI produced no rewrite -- '
            '${suggestion.explanation})');
        continue;
      }
      if (suggestion.confidence < minConfidence) {
        skipped.add('$relative (skipped: confidence '
            '${suggestion.confidence.toStringAsFixed(2)} < '
            '${minConfidence.toStringAsFixed(2)})');
        continue;
      }

      final fix = buildRefactorFix(
        file: file,
        projectPath: projectRoot,
        refactoredContent: suggestion.suggestedCode!,
        confidence: suggestion.confidence,
      );
      if (fix == null) {
        skipped.add('$relative (skipped: AI rewrite was identical to the '
            'existing file)');
        continue;
      }
      fixes.add(fix);
    }

    final result = await applyFixes(fixes, projectPath: projectRoot, apply: apply);

    final report = _buildReportJson(
      projectRoot: projectRoot,
      applied: apply,
      minConfidence: minConfidence,
      result: result,
      skipped: skipped,
    );
    _writeReports(out, reportFormat, report);
    _printSummary(result, skipped, projectRoot, out, reportFormat);
    return 0;
  }

  /// Assembles the canonical refactor-report JSON that both the persisted
  /// `report.json` and the human-readable reporters are built from.
  Map<String, dynamic> _buildReportJson({
    required String projectRoot,
    required bool applied,
    required double minConfidence,
    required ApplyFixesResult result,
    required List<String> skipped,
  }) {
    var linesAdded = 0;
    var linesRemoved = 0;
    final files = <Map<String, dynamic>>[];
    for (final fix in result.succeeded) {
      final counts = _countDiffLines(fix.diff);
      linesAdded += counts.added;
      linesRemoved += counts.removed;
      files.add({
        'file': p.relative(fix.file, from: projectRoot),
        'ruleId': fix.ruleId,
        'confidence': fix.confidence,
        'linesAdded': counts.added,
        'linesRemoved': counts.removed,
        'diff': fix.diff,
      });
    }

    final checkpoint = result.checkpoint;
    return {
      'project': projectRoot,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'applied': applied,
      'minConfidence': minConfidence,
      'checkpoint': checkpoint == null
          ? null
          : {'strategy': checkpoint.strategy.name, 'ref': checkpoint.ref},
      'totals': {
        'refactored': result.succeeded.length,
        'failed': result.failed.length,
        'skipped': skipped.length,
        'linesAdded': linesAdded,
        'linesRemoved': linesRemoved,
      },
      'files': files,
      'failed': result.failed
          .map((f) => {
                'file': p.relative(f.fix.file, from: projectRoot),
                'reason': f.reason,
              })
          .toList(),
      'skipped': skipped,
    };
  }

  /// Counts added (`+`) and removed (`-`) content lines in a unified diff,
  /// ignoring the `+++`/`---` file headers.
  ({int added, int removed}) _countDiffLines(String diff) {
    var added = 0;
    var removed = 0;
    for (final line in diff.split('\n')) {
      if (line.startsWith('+') && !line.startsWith('+++')) {
        added++;
      } else if (line.startsWith('-') && !line.startsWith('---')) {
        removed++;
      }
    }
    return (added: added, removed: removed);
  }

  void _writeReports(
    String out,
    String format,
    Map<String, dynamic> report,
  ) {
    final outDir = Directory(out)..createSync(recursive: true);
    File(p.join(outDir.path, 'report.json'))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));

    switch (format) {
      case 'html':
        File(p.join(outDir.path, 'report.html'))
            .writeAsStringSync(generateRefactorHtmlReport(report));
      case 'markdown':
        File(p.join(outDir.path, 'report.md'))
            .writeAsStringSync(generateRefactorMarkdownReport(report));
      case 'json':
        break; // report.json already written.
    }
  }

  void _printSummary(
    ApplyFixesResult result,
    List<String> skipped,
    String projectRoot,
    String out,
    String format,
  ) {
    final verb = result.dryRun ? 'Would refactor' : 'Refactored';
    print(
      '$verb ${result.succeeded.length} file(s)'
      '${result.dryRun ? ' (dry run -- pass --apply to write)' : ''}:',
    );
    for (final fix in result.succeeded) {
      print(
        '  ${p.relative(fix.file, from: projectRoot)} '
        '(confidence ${fix.confidence.toStringAsFixed(2)})',
      );
    }

    if (result.failed.isNotEmpty) {
      print('Failed to apply ${result.failed.length} refactor(s):');
      for (final failure in result.failed) {
        print(
          '  ${p.relative(failure.fix.file, from: projectRoot)}: '
          '${failure.reason}',
        );
      }
    }

    if (skipped.isNotEmpty) {
      print('Skipped ${skipped.length} file(s):');
      for (final note in skipped) {
        print('  $note');
      }
    }

    if (result.checkpoint != null) {
      print(
        'A git checkpoint was created before applying; revert with git if '
        'needed.',
      );
    }

    final ext = format == 'markdown'
        ? 'report.md'
        : format == 'json'
            ? 'report.json'
            : 'report.html';
    print('Report: ${p.join(out, ext)} (+ ${p.join(out, 'report.json')})');
  }
}
