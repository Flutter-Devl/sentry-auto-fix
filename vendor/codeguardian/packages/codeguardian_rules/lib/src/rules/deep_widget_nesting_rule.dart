import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags widget trees nested more than [maxDepth] levels deep (default 6).
///
/// Nesting is tracked structurally through `child:`/`children:` constructor
/// arguments — the idiomatic Flutter widget-tree shape — so this works
/// without depending on Flutter or resolving `Widget` itself. Only the
/// outermost instantiation of an over-deep chain is reported.
class DeepWidgetNestingRule implements CodeGuardianRule {
  /// Creates the rule with an optional maximum nesting [maxDepth].
  const DeepWidgetNestingRule({this.maxDepth = 6});

  /// The maximum `child`/`children` nesting depth allowed before a finding
  /// fires.
  final int maxDepth;

  @override
  String get id => 'deep-widget-nesting';

  @override
  List<Finding> check(ResolvedUnitResult unit) {
    final visitor = _Visitor(unit, maxDepth);
    unit.unit.accept(visitor);
    return visitor.findings;
  }
}

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.unit, this.maxDepth);

  final ResolvedUnitResult unit;
  final int maxDepth;
  final List<Finding> findings = [];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (!_isNestedChild(node)) {
      final depth = _depthOf(node);
      if (depth > maxDepth) {
        final location = unit.lineInfo.getLocation(node.offset);
        findings.add(Finding(
          ruleId: 'deep-widget-nesting',
          category: Category.performance,
          severity: Severity.medium,
          file: unit.path,
          line: location.lineNumber,
          column: location.columnNumber,
          message: 'Widget tree is nested $depth levels deep via '
              'child/children, exceeding the maximum of $maxDepth. Consider '
              'extracting subtrees into separate widgets.',
          snippet: lineSnippet(unit, location.lineNumber),
        ));
      }
    }
    super.visitInstanceCreationExpression(node);
  }

  /// Whether [node] is itself the `child:`/`children:` value of an enclosing
  /// instantiation (as opposed to the root of a widget subtree).
  bool _isNestedChild(InstanceCreationExpression node) {
    final parent = node.parent;
    if (parent is NamedExpression) {
      return parent.name.label.name == 'child' && _isChildSlot(parent);
    }
    if (parent is ListLiteral) {
      final listParent = parent.parent;
      return listParent is NamedExpression &&
          listParent.name.label.name == 'children' &&
          _isChildSlot(listParent);
    }
    return false;
  }

  bool _isChildSlot(NamedExpression namedExpression) {
    final argumentList = namedExpression.parent;
    return argumentList is ArgumentList &&
        argumentList.parent is InstanceCreationExpression;
  }

  int _depthOf(InstanceCreationExpression node) {
    var maxChildDepth = 0;
    for (final argument in node.argumentList.arguments) {
      if (argument is! NamedExpression) continue;
      final label = argument.name.label.name;
      if (label != 'child' && label != 'children') continue;
      maxChildDepth = _maxDepthIn(argument.expression, maxChildDepth);
    }
    return 1 + maxChildDepth;
  }

  int _maxDepthIn(Expression expression, int current) {
    if (expression is InstanceCreationExpression) {
      final depth = _depthOf(expression);
      return depth > current ? depth : current;
    }
    if (expression is ListLiteral) {
      for (final element in expression.elements) {
        if (element is Expression) {
          current = _maxDepthIn(element, current);
        }
      }
    }
    return current;
  }
}
