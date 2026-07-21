import 'package:analyzer/dart/analysis/results.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags blocks of at least [minLines] consecutive lines (default 6) that
/// reappear verbatim, modulo whitespace and trailing `//` comments, elsewhere
/// in the same file.
///
/// This is a simple normalized-token match, not an AST comparison: it
/// compares trimmed, whitespace-collapsed source lines directly. Reported
/// findings anchor on the second (duplicate) occurrence and name the line of
/// the first. Generated files are skipped: their mechanical repetition isn't
/// something a human should (or can) deduplicate.
class DuplicateCodeBlockRule implements CodeGuardianRule {
  /// Creates the rule with an optional minimum block size [minLines].
  const DuplicateCodeBlockRule({this.minLines = 6});

  /// The minimum number of consecutive matching lines to report.
  final int minLines;

  @override
  String get id => 'duplicate-code-block';

  @override
  List<Finding> check(ResolvedUnitResult unit) {
    if (isGeneratedFile(unit)) return const [];

    final lines = unit.content.split('\n');
    if (lines.length < minLines) return const [];

    final normalized = lines.map(_normalize).toList();
    final firstSeenAt = <String, int>{};
    final matches = <_Match>[];

    for (var i = 0; i <= normalized.length - minLines; i++) {
      final window = normalized.sublist(i, i + minLines);
      if (window.every((line) => line.isEmpty)) continue;

      final signature = window.join('\n');
      final firstStart = firstSeenAt[signature];
      if (firstStart == null) {
        firstSeenAt[signature] = i;
      } else if (i >= firstStart + minLines) {
        matches.add(_Match(start: i, duplicateOf: firstStart));
      }
    }

    final findings = <Finding>[];
    _Match? lastMatch;
    for (final match in matches) {
      // A run of matches shifted by exactly one line in lockstep is a single
      // longer duplicate seen through the sliding window; only its first
      // position is reported so one duplicate doesn't produce N findings.
      final isContinuation = lastMatch != null &&
          match.start == lastMatch.start + 1 &&
          match.duplicateOf == lastMatch.duplicateOf + 1;
      if (!isContinuation) {
        findings.add(_toFinding(unit, lines, match));
      }
      lastMatch = match;
    }

    return findings;
  }

  Finding _toFinding(ResolvedUnitResult unit, List<String> lines, _Match match) {
    final startLine = match.start + 1;
    final duplicateOfLine = match.duplicateOf + 1;
    final blockText =
        lines.sublist(match.start, match.start + minLines).join('\n');

    return Finding(
      ruleId: 'duplicate-code-block',
      category: Category.style,
      severity: Severity.low,
      file: unit.path,
      line: startLine,
      column: 1,
      message: 'This $minLines-line block duplicates the code starting at '
          'line $duplicateOfLine.',
      snippet: blockText,
    );
  }

  String _normalize(String line) {
    var result = line;
    final commentIndex = result.indexOf('//');
    if (commentIndex != -1) result = result.substring(0, commentIndex);
    return result.trim().replaceAll(RegExp(r'\s+'), ' ');
  }
}

class _Match {
  const _Match({required this.start, required this.duplicateOf});

  final int start;
  final int duplicateOf;
}
