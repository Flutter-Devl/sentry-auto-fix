import 'package:analyzer/dart/analysis/results.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags import directives that aren't referenced anywhere in the file.
///
/// This delegates to the Dart analyzer's own `UNUSED_IMPORT` diagnostic
/// (computed during resolution from the library's actual namespace), rather
/// than re-implementing name resolution, so it stays exact even for prefixed,
/// `show`/`hide`-qualified, and deferred imports.
class UnusedImportRule implements CodeGuardianRule {
  /// Creates the rule.
  const UnusedImportRule();

  @override
  String get id => 'unused-import';

  @override
  List<Finding> check(ResolvedUnitResult unit) {
    final findings = <Finding>[];

    for (final error in unit.errors) {
      if (error.errorCode.name != 'UNUSED_IMPORT') continue;

      final location = unit.lineInfo.getLocation(error.offset);
      findings.add(Finding(
        ruleId: 'unused-import',
        category: Category.style,
        severity: Severity.low,
        file: unit.path,
        line: location.lineNumber,
        column: location.columnNumber,
        message: error.message,
        snippet: lineSnippet(unit, location.lineNumber),
      ));
    }

    return findings;
  }
}
