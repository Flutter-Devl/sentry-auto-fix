import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags animated subtrees that skip `RepaintBoundary`, so painting work for
/// content that doesn't itself change repeats on every animation frame
/// anyway.
///
/// Two shapes are checked:
///  * `AnimatedBuilder(builder: (context, child) => ...)` -- the widget the
///    `builder` callback returns is rebuilt (and repainted) on every tick,
///    so it should be wrapped in its own `RepaintBoundary`.
///  * `Transform(...)` / `Transform.rotate/scale/translate(...)` -- these
///    repaint their whole child whenever the transform changes, so the
///    child should be isolated behind a `RepaintBoundary`.
class MissingRepaintBoundaryRule implements CodeGuardianRule {
  /// Creates the rule.
  const MissingRepaintBoundaryRule();

  @override
  String get id => 'missing-repaint-boundary';

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

    final typeName = node.constructorName.type.name2.lexeme;
    if (typeName == 'AnimatedBuilder') {
      _checkAnimatedBuilder(node);
    } else if (typeName == 'Transform') {
      _checkTransformChild(node);
    }
  }

  void _checkAnimatedBuilder(InstanceCreationExpression node) {
    for (final argument in node.argumentList.arguments) {
      if (argument is! NamedExpression) continue;
      if (argument.name.label.name != 'builder') continue;

      final builder = argument.expression;
      if (builder is! FunctionExpression) continue;

      final unwrapped = _returnedExpressions(builder)
          .where((expression) => !_isWrappedInRepaintBoundary(expression));
      if (unwrapped.isNotEmpty) _report(node, 'AnimatedBuilder');
      return;
    }
  }

  void _checkTransformChild(InstanceCreationExpression node) {
    for (final argument in node.argumentList.arguments) {
      if (argument is! NamedExpression) continue;
      if (argument.name.label.name != 'child') continue;
      if (!_isWrappedInRepaintBoundary(argument.expression)) {
        _report(node, 'Transform');
      }
      return;
    }
  }

  bool _isWrappedInRepaintBoundary(Expression expression) =>
      expression is InstanceCreationExpression &&
      expression.constructorName.type.name2.lexeme == 'RepaintBoundary';

  /// The expression(s) an `AnimatedBuilder.builder` callback can return.
  Iterable<Expression> _returnedExpressions(FunctionExpression function) {
    final body = function.body;
    if (body is ExpressionFunctionBody) return [body.expression];
    if (body is BlockFunctionBody) {
      final collector = _ReturnCollector();
      body.block.accept(collector);
      return collector.expressions;
    }
    return const [];
  }

  void _report(InstanceCreationExpression node, String widgetName) {
    final location = unit.lineInfo.getLocation(node.offset);
    findings.add(Finding(
      ruleId: 'missing-repaint-boundary',
      category: Category.performance,
      severity: Severity.medium,
      file: unit.path,
      line: location.lineNumber,
      column: location.columnNumber,
      message: '$widgetName repaints its child on every animation frame; '
          'wrap the child in a RepaintBoundary to avoid repainting content '
          "that hasn't changed.",
      snippet: lineSnippet(unit, location.lineNumber),
    ));
  }
}

/// Collects the expressions of top-level `return` statements within a
/// function body, without descending into further-nested closures (whose
/// returns belong to a different builder).
class _ReturnCollector extends RecursiveAstVisitor<void> {
  final List<Expression> expressions = [];

  @override
  void visitReturnStatement(ReturnStatement node) {
    final expression = node.expression;
    if (expression != null) expressions.add(expression);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
}
