import 'dart:convert';

import 'package:codeguardian_core/codeguardian_core.dart';

/// Severities ordered least to most serious, matching [Severity]'s
/// declaration order.
const List<String> _severityOrder = ['info', 'low', 'medium', 'high', 'critical'];

/// Maps a CodeGuardian [Severity] label to a SARIF `result.level`.
///
/// SARIF only has four levels (`none`/`note`/`warning`/`error`), so this
/// collapses our five severities: critical/high both indicate a real
/// exploitable/breaking problem (`error`), medium is a `warning`, and
/// low/info are downgraded to `note`.
String _sarifLevel(String severity) {
  switch (severity) {
    case 'critical':
    case 'high':
      return 'error';
    case 'medium':
      return 'warning';
    default:
      return 'note';
  }
}

/// Builds the SARIF 2.1.0 `run.tool.driver.rules` array: one
/// `reportingDescriptor` per distinct rule id present in [findings], in
/// first-seen order. `defaultConfiguration.level` is derived from the most
/// severe occurrence of that rule (individual results carry their own
/// `level` regardless, so this is only a suggested default).
List<Map<String, dynamic>> _buildRules(List<Map<String, dynamic>> findings) {
  final ruleIds = <String>[];
  final maxSeverityByRule = <String, String>{};
  final categoryByRule = <String, String>{};

  for (final finding in findings) {
    final ruleId = finding['ruleId'] as String? ?? 'unknown';
    if (!ruleIds.contains(ruleId)) ruleIds.add(ruleId);

    final severity = finding['severity'] as String? ?? 'info';
    final currentMax = maxSeverityByRule[ruleId];
    if (currentMax == null ||
        _severityOrder.indexOf(severity) > _severityOrder.indexOf(currentMax)) {
      maxSeverityByRule[ruleId] = severity;
    }

    categoryByRule.putIfAbsent(ruleId, () => finding['category'] as String? ?? 'other');
  }

  return ruleIds.map((ruleId) {
    return {
      'id': ruleId,
      'shortDescription': {'text': _humanizeRuleId(ruleId)},
      'defaultConfiguration': {'level': _sarifLevel(maxSeverityByRule[ruleId] ?? 'info')},
      'properties': {
        'tags': [categoryByRule[ruleId] ?? 'other'],
      },
    };
  }).toList();
}

/// Builds the SARIF 2.1.0 `run.results` array: one `result` per finding.
List<Map<String, dynamic>> _buildResults(List<Map<String, dynamic>> findings) {
  return findings.map((finding) {
    final ruleId = finding['ruleId'] as String? ?? 'unknown';
    final severity = finding['severity'] as String? ?? 'info';
    final file = finding['file'] as String? ?? '';
    final line = finding['line'] as int? ?? 1;
    final column = finding['column'] as int? ?? 1;
    final message = finding['message'] as String? ?? '';
    final category = finding['category'] as String? ?? 'other';
    final cweId = finding['cweId'] as String?;
    final masvsId = finding['masvsId'] as String?;

    return {
      'ruleId': ruleId,
      'level': _sarifLevel(severity),
      'message': {'text': message},
      'locations': [
        {
          'physicalLocation': {
            // Percent-encoded so the value is always a well-formed URI
            // reference, even when the underlying file path has spaces or
            // other characters that aren't valid in a raw URI (e.g. this
            // very repo's directory name).
            'artifactLocation': {'uri': Uri(path: file).toString()},
            'region': {'startLine': line, 'startColumn': column},
          },
        },
      ],
      'properties': {
        'category': category,
        if (cweId != null) 'cweId': cweId,
        if (masvsId != null) 'masvsId': masvsId,
      },
    };
  }).toList();
}

/// Builds a SARIF 2.1.0 log as a plain JSON-serializable [Map] from
/// canonical findings JSON (the shape `Finding.toJson()` produces).
///
/// This is the structural counterpart to [generateSarifReport] (which just
/// JSON-encodes this map): exposing the [Map] directly lets tests validate
/// its shape against the official SARIF schema without a decode round-trip.
Map<String, dynamic> buildSarifLog(
  List<Map<String, dynamic>> findings, {
  String toolName = 'CodeGuardian AI',
  String toolVersion = '0.1.0',
  String? informationUri,
}) {
  return {
    r'$schema':
        'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json',
    'version': '2.1.0',
    'runs': [
      {
        'tool': {
          'driver': {
            'name': toolName,
            'version': toolVersion,
            if (informationUri != null) 'informationUri': informationUri,
            'rules': _buildRules(findings),
          },
        },
        'results': _buildResults(findings),
      },
    ],
  };
}

/// Generates a SARIF 2.1.0 report (as pretty-printed JSON text) from
/// canonical findings JSON.
///
/// SARIF (Static Analysis Results Interchange Format) is the format GitHub
/// code scanning, Azure DevOps, and most other CI security dashboards
/// consume, so this is the format to use when uploading results to those
/// systems rather than for human reading.
String generateSarifReport(
  List<Map<String, dynamic>> findings, {
  String toolName = 'CodeGuardian AI',
  String toolVersion = '0.1.0',
  String? informationUri,
}) {
  final log = buildSarifLog(
    findings,
    toolName: toolName,
    toolVersion: toolVersion,
    informationUri: informationUri,
  );
  return const JsonEncoder.withIndent('  ').convert(log);
}

/// Convenience overload of [generateSarifReport] for callers that already
/// have [Finding] objects rather than decoded JSON.
String generateSarifReportFromFindings(
  List<Finding> findings, {
  String toolName = 'CodeGuardian AI',
  String toolVersion = '0.1.0',
  String? informationUri,
}) {
  return generateSarifReport(
    findings.map((f) => f.toJson()).toList(),
    toolName: toolName,
    toolVersion: toolVersion,
    informationUri: informationUri,
  );
}

String _humanizeRuleId(String ruleId) {
  final words = ruleId.split(RegExp('[-_]')).where((w) => w.isNotEmpty);
  return words.map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
}
