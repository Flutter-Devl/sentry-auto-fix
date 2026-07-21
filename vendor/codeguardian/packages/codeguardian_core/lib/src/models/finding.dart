import 'package:meta/meta.dart';

import 'category.dart';
import 'severity.dart';

/// A single issue reported by a rule at a specific location in the source.
///
/// A [Finding] is an immutable value object. Two findings are considered equal
/// when every field matches, which makes them convenient to deduplicate and to
/// assert against in tests.
@immutable
class Finding {
  /// Creates a finding.
  ///
  /// [line] and [column] are 1-based, matching the convention used by the
  /// Dart analyzer's `LineInfo` and by most editors.
  const Finding({
    required this.ruleId,
    required this.category,
    required this.severity,
    required this.file,
    required this.line,
    required this.column,
    required this.message,
    required this.snippet,
    this.cweId,
    this.masvsId,
  });

  /// Identifier of the rule that produced this finding (e.g. `hardcoded_secret`).
  final String ruleId;

  /// The class of problem this finding represents.
  final Category category;

  /// How serious this finding is.
  final Severity severity;

  /// Absolute path of the file the finding was reported in.
  final String file;

  /// 1-based line number of the finding.
  final int line;

  /// 1-based column number of the finding.
  final int column;

  /// Human-readable description of the problem.
  final String message;

  /// The offending source text (typically the line or expression).
  final String snippet;

  /// Optional Common Weakness Enumeration id, e.g. `CWE-798`.
  final String? cweId;

  /// Optional OWASP MASVS control id, e.g. `MASVS-CRYPTO-1`.
  final String? masvsId;

  /// Returns a copy of this finding with the given fields replaced.
  Finding copyWith({
    String? ruleId,
    Category? category,
    Severity? severity,
    String? file,
    int? line,
    int? column,
    String? message,
    String? snippet,
    String? cweId,
    String? masvsId,
  }) {
    return Finding(
      ruleId: ruleId ?? this.ruleId,
      category: category ?? this.category,
      severity: severity ?? this.severity,
      file: file ?? this.file,
      line: line ?? this.line,
      column: column ?? this.column,
      message: message ?? this.message,
      snippet: snippet ?? this.snippet,
      cweId: cweId ?? this.cweId,
      masvsId: masvsId ?? this.masvsId,
    );
  }

  /// A JSON-serializable representation of this finding.
  Map<String, dynamic> toJson() => {
        'ruleId': ruleId,
        'category': category.label,
        'severity': severity.label,
        'file': file,
        'line': line,
        'column': column,
        'message': message,
        'snippet': snippet,
        if (cweId != null) 'cweId': cweId,
        if (masvsId != null) 'masvsId': masvsId,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Finding &&
          runtimeType == other.runtimeType &&
          ruleId == other.ruleId &&
          category == other.category &&
          severity == other.severity &&
          file == other.file &&
          line == other.line &&
          column == other.column &&
          message == other.message &&
          snippet == other.snippet &&
          cweId == other.cweId &&
          masvsId == other.masvsId;

  @override
  int get hashCode => Object.hash(
        ruleId,
        category,
        severity,
        file,
        line,
        column,
        message,
        snippet,
        cweId,
        masvsId,
      );

  @override
  String toString() =>
      'Finding($ruleId, ${severity.label}, $file:$line:$column, "$message")';
}
