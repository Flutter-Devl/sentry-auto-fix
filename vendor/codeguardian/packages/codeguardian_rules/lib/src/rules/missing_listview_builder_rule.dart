import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags `ListView(children: ...)` (the default, eager constructor) whose
/// `children` come from a dynamically generated list -- `.map(...).toList()`
/// or `List.generate(...)` -- rather than `ListView.builder`.
///
/// The default `ListView` constructor builds every child up front, even ones
/// that never scroll into view. A generated `children` list is the signal
/// that the list is data-driven (and so may be long) rather than a small,
/// fixed set of widgets, where `ListView.builder` should be used instead to
/// build items lazily.
class MissingListViewBuilderRule implements CodeGuardianRule {
  /// Creates the rule.
  const MissingListViewBuilderRule();

  @override
  String get id => 'missing-listview-builder';

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

    if (node.constructorName.type.name2.lexeme != 'ListView') return;
    // Named constructors (.builder, .separated, .custom) already build
    // lazily; only the default (unnamed) constructor is eager.
    if (node.constructorName.name != null) return;

    for (final argument in node.argumentList.arguments) {
      if (argument is! NamedExpression) continue;
      if (argument.name.label.name != 'children') continue;
      if (!_isDynamicallyGenerated(argument.expression)) continue;

      final location = unit.lineInfo.getLocation(node.offset);
      findings.add(Finding(
        ruleId: 'missing-listview-builder',
        category: Category.performance,
        severity: Severity.medium,
        file: unit.path,
        line: location.lineNumber,
        column: location.columnNumber,
        message: 'ListView(children: ...) is built from a generated list, '
            'so every item is built eagerly regardless of how many are ever '
            'visible; use ListView.builder to build items lazily as they '
            'scroll into view.',
        snippet: lineSnippet(unit, location.lineNumber),
      ));
    }
  }

  /// Whether [expression] looks like a programmatically generated
  /// collection: `<iterable>.map(...).toList()` or `List.generate(...)`.
  bool _isDynamicallyGenerated(Expression expression) {
    if (expression is! MethodInvocation) return false;

    final target = expression.target;
    if (expression.methodName.name == 'toList' &&
        target is MethodInvocation &&
        target.methodName.name == 'map') {
      return true;
    }
    if (expression.methodName.name == 'generate' &&
        target is SimpleIdentifier &&
        target.name == 'List') {
      return true;
    }
    return false;
  }
}
