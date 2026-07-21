import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags methods and functions whose cyclomatic complexity exceeds
/// [threshold] (default 15).
///
/// Complexity starts at 1 for the body itself and gains 1 for every `if`,
/// loop, `catch`, `switch`/pattern case, `?:`, and `&&`/`||` operator —
/// the standard McCabe cyclomatic-complexity count of independent paths
/// through the body.
///
/// Nested closures (callbacks, builders, etc.) are excluded: cyclomatic
/// complexity is a per-function metric, so a method that merely fires off a
/// callback shouldn't be blamed for that callback's own branching -- doing
/// so recommends splitting up a method that has nothing to split.
class LongMethodRule implements CodeGuardianRule {
  /// Creates the rule with an optional complexity [threshold].
  const LongMethodRule({this.threshold = 15});

  /// The maximum cyclomatic complexity allowed before a finding fires.
  final int threshold;

  @override
  String get id => 'long-method';

  @override
  List<Finding> check(ResolvedUnitResult unit) {
    final visitor = _DeclarationVisitor(unit, threshold);
    unit.unit.accept(visitor);
    return visitor.findings;
  }
}

class _DeclarationVisitor extends RecursiveAstVisitor<void> {
  _DeclarationVisitor(this.unit, this.threshold);

  final ResolvedUnitResult unit;
  final int threshold;
  final List<Finding> findings = [];

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _check(node.name.lexeme, node.name.offset, node.body);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _check(node.name.lexeme, node.name.offset, node.functionExpression.body);
    super.visitFunctionDeclaration(node);
  }

  void _check(String name, int nameOffset, FunctionBody body) {
    final complexity = _ComplexityVisitor();
    body.accept(complexity);
    if (complexity.value <= threshold) return;

    final location = unit.lineInfo.getLocation(nameOffset);
    findings.add(Finding(
      ruleId: 'long-method',
      category: Category.style,
      severity: Severity.medium,
      file: unit.path,
      line: location.lineNumber,
      column: location.columnNumber,
      message: "'$name' has a cyclomatic complexity of ${complexity.value}, "
          'which exceeds the threshold of $threshold. Consider splitting it '
          'into smaller methods.',
      snippet: lineSnippet(unit, location.lineNumber),
    ));
  }
}

class _ComplexityVisitor extends RecursiveAstVisitor<void> {
  int value = 1;

  @override
  void visitIfStatement(IfStatement node) {
    value++;
    super.visitIfStatement(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    value++;
    super.visitForStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    value++;
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    value++;
    super.visitDoStatement(node);
  }

  @override
  void visitSwitchCase(SwitchCase node) {
    value++;
    super.visitSwitchCase(node);
  }

  @override
  void visitSwitchPatternCase(SwitchPatternCase node) {
    value++;
    super.visitSwitchPatternCase(node);
  }

  @override
  void visitCatchClause(CatchClause node) {
    value++;
    super.visitCatchClause(node);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    value++;
    super.visitConditionalExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (node.operator.type == TokenType.AMPERSAND_AMPERSAND ||
        node.operator.type == TokenType.BAR_BAR) {
      value++;
    }
    super.visitBinaryExpression(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Don't recurse: a nested closure is its own unit of complexity, not
    // part of the enclosing method's control flow.
  }
}
