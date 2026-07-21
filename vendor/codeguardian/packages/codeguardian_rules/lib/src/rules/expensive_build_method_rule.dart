import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags widget `build(BuildContext context)` methods that directly perform
/// known-expensive work -- parsing/encoding JSON, or constructing a `RegExp`
/// or `DateFormat` -- which then reruns on every rebuild instead of being
/// computed once and cached.
class ExpensiveBuildMethodRule implements CodeGuardianRule {
  /// Creates the rule.
  const ExpensiveBuildMethodRule();

  @override
  String get id => 'expensive-build-method';

  @override
  List<Finding> check(ResolvedUnitResult unit) {
    final visitor = _DeclarationVisitor(unit);
    unit.unit.accept(visitor);
    return visitor.findings;
  }
}

class _DeclarationVisitor extends RecursiveAstVisitor<void> {
  _DeclarationVisitor(this.unit);

  final ResolvedUnitResult unit;
  final List<Finding> findings = [];

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    super.visitMethodDeclaration(node);
    if (!_isWidgetBuildMethod(node)) return;

    final visitor = _ExpensiveWorkVisitor(unit);
    node.body.accept(visitor);
    findings.addAll(visitor.findings);
  }

  bool _isWidgetBuildMethod(MethodDeclaration node) {
    if (node.name.lexeme != 'build') return false;
    if (node.returnType?.toSource() != 'Widget') return false;

    final parameters = node.parameters?.parameters ?? const [];
    if (parameters.isEmpty) return false;
    final firstParameter = parameters.first;
    return firstParameter is SimpleFormalParameter &&
        firstParameter.type?.toSource() == 'BuildContext';
  }
}

class _ExpensiveWorkVisitor extends RecursiveAstVisitor<void> {
  _ExpensiveWorkVisitor(this.unit);

  final ResolvedUnitResult unit;
  final List<Finding> findings = [];

  static const _expensiveFunctionNames = {'jsonDecode', 'jsonEncode'};
  static const _expensiveTypeNames = {'RegExp', 'DateFormat'};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);

    final name = node.methodName.name;
    final target = node.target;
    final isJsonCodecCall = (name == 'decode' || name == 'encode') &&
        target is SimpleIdentifier &&
        target.name == 'json';

    if (_expensiveFunctionNames.contains(name) || isJsonCodecCall) {
      _report(node.offset, '$name(...)');
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    super.visitInstanceCreationExpression(node);

    final typeName = node.constructorName.type.name2.lexeme;
    if (_expensiveTypeNames.contains(typeName)) {
      _report(node.offset, '$typeName(...)');
    }
  }

  void _report(int offset, String what) {
    final location = unit.lineInfo.getLocation(offset);
    findings.add(Finding(
      ruleId: 'expensive-build-method',
      category: Category.performance,
      severity: Severity.medium,
      file: unit.path,
      line: location.lineNumber,
      column: location.columnNumber,
      message: '$what runs on every rebuild inside build(); hoist it out '
          '(e.g. into initState, a memoized field, or a top-level const) '
          'instead of recomputing it on every frame.',
      snippet: lineSnippet(unit, location.lineNumber),
    ));
  }
}
