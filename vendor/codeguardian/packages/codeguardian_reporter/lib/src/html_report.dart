import 'dart:convert';

import 'package:codeguardian_core/codeguardian_core.dart';

import 'report_css.dart';
import 'report_script.dart';

/// File extensions treated as native (Android/iOS platform config or
/// native-language source) rather than Dart/project files.
///
/// Classifying by extension (instead of, say, hardcoding the native rule
/// ids from `codeguardian_native`) keeps this package independent of which
/// packages produced a finding -- it only needs to know the shape of the
/// canonical findings JSON.
const Set<String> nativeFileExtensions = {
  '.xml',
  '.plist',
  '.kt',
  '.java',
  '.swift',
  '.m',
  '.mm',
  '.h',
};

/// Whether [finding]'s file looks like a native (Android/iOS) file rather
/// than a Dart/project file, based on its extension.
bool isNativeFinding(Map<String, dynamic> finding) {
  final file = finding['file'] as String? ?? '';
  final dot = file.lastIndexOf('.');
  if (dot == -1) return false;
  return nativeFileExtensions.contains(file.substring(dot));
}

/// Per-severity penalty weights [computeReportScore] subtracts from a
/// starting score of 100.
///
/// Matches `codeguardian_validator`'s `computeScore` formula exactly, so
/// the number shown in a report agrees with the number a `validate` run
/// would compute for the same findings. Duplicated here (rather than
/// depended on) so this package can generate a report from plain findings
/// JSON without needing the validator's config/gate machinery.
const Map<String, num> reportScoreWeights = {
  'critical': 25,
  'high': 10,
  'medium': 4,
  'low': 1,
  'info': 0,
};

/// Computes a summary score from [findings] (see [reportScoreWeights]).
/// Always in the range `[0, 100]`.
num computeReportScore(List<Map<String, dynamic>> findings) {
  var penalty = 0.0;
  for (final finding in findings) {
    final severity = finding['severity'] as String? ?? 'info';
    penalty += reportScoreWeights[severity] ?? 0;
  }
  final score = 100 - penalty;
  return score < 0 ? 0 : score;
}

/// Generates a single, self-contained interactive HTML report from
/// canonical findings JSON (the shape `Finding.toJson()` produces: each
/// entry has `ruleId`, `category`, `severity`, `file`, `line`, `column`,
/// `message`, `snippet`, and optionally `cweId`/`masvsId`).
///
/// The report has:
///  * A summary header with an overall score (see [computeReportScore])
///    and a count badge per severity.
///  * Two independent findings tables -- Dart and native (see
///    [isNativeFinding]) -- each sortable by clicking a column header
///    (severity sorts by rank: critical > high > medium > low > info, not
///    alphabetically) and filterable by category via checkboxes.
///
/// Everything -- CSS, JS, and the findings data itself -- is inlined into
/// one HTML file: it opens directly from disk with no server, build step,
/// or network access, and makes no external requests.
///
/// [generatedAt] defaults to the current time; pass an explicit value for
/// reproducible output (e.g. in tests).
String generateHtmlReport(
  List<Map<String, dynamic>> findings, {
  String title = 'CodeGuardian AI Report',
  DateTime? generatedAt,
}) {
  final dartFindings = findings.where((f) => !isNativeFinding(f)).toList();
  final nativeFindings = findings.where(isNativeFinding).toList();

  final score = computeReportScore(findings);
  final countsBySeverity = <String, int>{};
  for (final finding in findings) {
    final severity = finding['severity'] as String? ?? 'info';
    countsBySeverity[severity] = (countsBySeverity[severity] ?? 0) + 1;
  }

  final timestamp = (generatedAt ?? DateTime.now()).toUtc().toIso8601String();

  final badgesHtml = StringBuffer();
  for (final severity in ['critical', 'high', 'medium', 'low', 'info']) {
    final count = countsBySeverity[severity] ?? 0;
    if (count == 0) continue;
    badgesHtml.write(
      '<span class="badge severity-$severity">$count '
      '${_escapeHtml(_titleCase(severity))}</span>',
    );
  }

  final scoreColor = _scoreColor(score);

  final html = StringBuffer()
    ..writeln('<!doctype html>')
    ..writeln('<html lang="en">')
    ..writeln('<head>')
    ..writeln('<meta charset="utf-8">')
    ..writeln('<meta name="viewport" content="width=device-width, initial-scale=1">')
    ..writeln('<title>${_escapeHtml(title)}</title>')
    ..writeln('<style>')
    ..writeln(reportCss)
    ..writeln('</style>')
    ..writeln('</head>')
    ..writeln('<body>')
    ..writeln('<header class="summary">')
    ..writeln(
      '<div class="score-circle" style="--score-color: $scoreColor">'
      '${score.toStringAsFixed(0)}</div>',
    )
    ..writeln('<div class="summary-text">')
    ..writeln('<h1>${_escapeHtml(title)}</h1>')
    ..writeln(
      '<p class="summary-meta">Generated $timestamp &middot; '
      '${findings.length} finding${findings.length == 1 ? '' : 's'} '
      '(${dartFindings.length} Dart, ${nativeFindings.length} native)</p>',
    )
    ..writeln('<div class="badge-row">$badgesHtml</div>')
    ..writeln('</div>')
    ..writeln('</header>')
    ..writeln('<main>')
    ..write(_sectionHtml(id: 'dart-section', heading: 'Dart Findings'))
    ..write(_sectionHtml(id: 'native-section', heading: 'Native Findings'))
    ..writeln('</main>')
    ..writeln(
      '<footer>Generated by CodeGuardian AI &middot; '
      '${findings.length} finding${findings.length == 1 ? '' : 's'} '
      'analyzed</footer>',
    )
    ..writeln('<script>')
    ..writeln('var DART_FINDINGS = ${_embedJson(dartFindings)};')
    ..writeln('var NATIVE_FINDINGS = ${_embedJson(nativeFindings)};')
    ..writeln(reportScript)
    ..writeln("initSection('dart-section', DART_FINDINGS);")
    ..writeln("initSection('native-section', NATIVE_FINDINGS);")
    ..writeln('</script>')
    ..writeln('</body>')
    ..writeln('</html>');

  return html.toString();
}

/// Convenience overload of [generateHtmlReport] for callers that already
/// have [Finding] objects rather than decoded JSON.
String generateHtmlReportFromFindings(
  List<Finding> findings, {
  String title = 'CodeGuardian AI Report',
  DateTime? generatedAt,
}) {
  return generateHtmlReport(
    findings.map((f) => f.toJson()).toList(),
    title: title,
    generatedAt: generatedAt,
  );
}

String _sectionHtml({required String id, required String heading}) {
  return '''
<section class="findings" id="$id">
<h2>${_escapeHtml(heading)} <span class="count">0</span></h2>
<div class="filters"></div>
<div class="table-scroll">
<table>
<thead>
<tr>
<th data-key="severity">Severity</th>
<th data-key="category">Category</th>
<th data-key="ruleId">Rule</th>
<th data-key="file">File</th>
<th data-key="line">Line</th>
<th data-key="message">Message</th>
</tr>
</thead>
<tbody></tbody>
</table>
</div>
<p class="empty-state" hidden>No ${_escapeHtml(heading.toLowerCase())} &#127881;</p>
</section>
''';
}

/// Encodes [data] as JSON for embedding inside an inline `<script>` tag.
///
/// `jsonEncode` alone isn't safe to drop into HTML as-is: if any string
/// value contains the literal sequence `</script`, the browser's HTML
/// parser closes the script tag right there, corrupting the page (and,
/// depending on what follows, potentially becoming an injection vector).
/// Escaping every `<` as its unicode escape sidesteps that -- `JSON.parse`
/// (which the browser uses implicitly for a JS array/object literal here)
/// treats `<` and a literal `<` identically, but the literal
/// sequence `</script` never appears in the raw HTML source.
String _embedJson(Object? data) {
  // The 6 literal characters backslash, u, 0, 0, 3, c -- i.e. the JSON/JS
  // unicode escape for '<' -- built from explicit char codes so there's no
  // ambiguity about whether this is an escape sequence or the character
  // '<' itself.
  final lessThanEscape = String.fromCharCodes([0x5c, 0x75, 0x30, 0x30, 0x33, 0x63]);
  final encoded = jsonEncode(data);
  final buffer = StringBuffer();
  for (final rune in encoded.runes) {
    if (rune == 0x3c) {
      buffer.write(lessThanEscape);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

String _escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _titleCase(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

String _scoreColor(num score) {
  if (score >= 90) return '#16a34a';
  if (score >= 70) return '#ca8a04';
  if (score >= 50) return '#ea580c';
  return '#dc2626';
}
