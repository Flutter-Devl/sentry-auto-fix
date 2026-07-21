import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags string literals that hardcode a plaintext `http://` URL, which
/// transmits data (and often credentials) unencrypted.
///
/// `http://localhost` and `http://127.0.0.1` are exempt since they're
/// commonly used for local development and never leave the device.
class InsecureHttpUrlRule implements CodeGuardianRule {
  /// Creates the rule.
  const InsecureHttpUrlRule();

  @override
  String get id => 'insecure-http-url';

  @override
  List<Finding> check(ResolvedUnitResult unit) {
    final visitor = _Visitor(unit);
    unit.unit.accept(visitor);
    return visitor.findings;
  }
}

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.unit);

  final ResolvedUnitResult unit;
  final List<Finding> findings = [];

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    super.visitSimpleStringLiteral(node);

    final value = node.value;
    if (!value.startsWith('http://')) return;
    if (value.startsWith('http://localhost') ||
        value.startsWith('http://127.0.0.1')) {
      return;
    }

    final location = unit.lineInfo.getLocation(node.offset);
    findings.add(Finding(
      ruleId: 'insecure-http-url',
      category: Category.security,
      severity: Severity.medium,
      file: unit.path,
      line: location.lineNumber,
      column: location.columnNumber,
      message: 'Hardcoded plaintext URL transmits data unencrypted; use '
          "'https://' instead of '$value'.",
      snippet: lineSnippet(unit, location.lineNumber),
      cweId: 'CWE-319',
      masvsId: 'MASVS-NETWORK-1',
    ));
  }
}
