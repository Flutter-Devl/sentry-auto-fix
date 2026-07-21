import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags object instantiations that could be `const` but aren't.
///
/// A call site is flagged when the invoked constructor is declared `const`,
/// every argument is a compile-time-constant-eligible expression, and the
/// instantiation isn't already treated as const (neither the `const` keyword
/// is present nor is the expression already in an implicit constant context).
class MissingConstConstructorRule implements CodeGuardianRule {
  /// Creates the rule.
  const MissingConstConstructorRule();

  @override
  String get id => 'missing-const-constructor';

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
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    super.visitInstanceCreationExpression(node);

    if (node.isConst) return;

    final constructorElement = node.constructorName.staticElement;
    if (constructorElement == null || !constructorElement.isConst) return;

    if (!node.argumentList.arguments.every(_isConstantEligible)) return;

    final location = unit.lineInfo.getLocation(node.offset);
    final typeName = node.constructorName.type.toSource();
    findings.add(Finding(
      ruleId: 'missing-const-constructor',
      category: Category.performance,
      severity: Severity.low,
      file: unit.path,
      line: location.lineNumber,
      column: location.columnNumber,
      message: "'$typeName' has a const constructor and every argument is "
          "constant; add 'const' to avoid rebuilding it unnecessarily.",
      snippet: lineSnippet(unit, location.lineNumber),
    ));
  }

  bool _isConstantEligible(Expression expression) {
    if (expression is NamedExpression) {
      return _isConstantEligible(expression.expression);
    }
    if (expression is NullLiteral ||
        expression is BooleanLiteral ||
        expression is IntegerLiteral ||
        expression is DoubleLiteral ||
        expression is SymbolLiteral ||
        expression is SimpleStringLiteral) {
      return true;
    }
    if (expression is InstanceCreationExpression) {
      final element = expression.constructorName.staticElement;
      final isConstConstructor = expression.isConst ||
          (element != null && element.isConst);
      return isConstConstructor &&
          expression.argumentList.arguments.every(_isConstantEligible);
    }
    return false;
  }
}
