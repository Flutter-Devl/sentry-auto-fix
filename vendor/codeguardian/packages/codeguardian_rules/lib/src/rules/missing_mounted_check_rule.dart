import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags `BuildContext`/`setState` use after an `await` with no `mounted`
/// guard in between, inside a `State` subclass.
///
/// By the time an awaited `Future` completes, the widget may already have
/// been removed from the tree (the user navigated away, the parent rebuilt
/// without it, ...) -- its `State` is then disposed, and touching
/// `context`/calling `setState` throws or silently misbehaves. The standard
/// fix is a `mounted` guard (`if (!mounted) return;` or `if (context.mounted)
/// { ... }`) right after the `await`.
///
/// This is a linear scan of a method body's *direct* top-level statements
/// only -- it does not do full control-flow analysis. An `await` or a
/// `mounted` guard nested inside an `if`, loop, or `try` block isn't
/// tracked, so code that's more nested than a flat sequence of statements
/// can produce false negatives. Treat this as a prompt to double-check the
/// method, not as a proof one way or the other.
class MissingMountedCheckRule implements CodeGuardianRule {
  /// Creates the rule.
  const MissingMountedCheckRule();

  @override
  String get id => 'missing-mounted-check';

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

    if (!_isDeclaredInStateSubclass(node)) return;
    final body = node.body;
    if (body is! BlockFunctionBody) return;

    findings.addAll(_scanForUnguardedUse(unit, body.block));
  }

  bool _isDeclaredInStateSubclass(AstNode node) {
    var current = node.parent;
    while (current != null) {
      if (current is ClassDeclaration) {
        return current.extendsClause?.superclass.name2.lexeme == 'State';
      }
      current = current.parent;
    }
    return false;
  }
}

/// Scans [block]'s direct statements in order, tracking whether an `await`
/// has occurred without a subsequent `mounted` guard, and reports each
/// `setState`/`context` use found in that unsafe window.
List<Finding> _scanForUnguardedUse(ResolvedUnitResult unit, Block block) {
  final findings = <Finding>[];
  var awaited = false;

  for (final statement in block.statements) {
    if (_isMountedGuard(statement)) {
      awaited = false;
      continue;
    }

    if (awaited && _usesContextOrSetState(statement)) {
      final location = unit.lineInfo.getLocation(statement.offset);
      findings.add(Finding(
        ruleId: 'missing-mounted-check',
        category: Category.correctness,
        severity: Severity.high,
        file: unit.path,
        line: location.lineNumber,
        column: location.columnNumber,
        message: 'This uses BuildContext/setState after an await with no '
            "'mounted' check in between; the State may already be disposed "
            "by the time the await completes. Add 'if (!mounted) return;' "
            'right after the await.',
        snippet: lineSnippet(unit, location.lineNumber),
      ));
    }

    if (_containsAwait(statement)) {
      awaited = true;
    }
  }

  return findings;
}

bool _isMountedGuard(Statement statement) =>
    statement is IfStatement && _mentionsMounted(statement.expression);

bool _mentionsMounted(Expression expression) {
  if (expression is PrefixExpression) return _mentionsMounted(expression.operand);
  if (expression is SimpleIdentifier) return expression.name == 'mounted';
  if (expression is PropertyAccess) {
    return expression.propertyName.name == 'mounted';
  }
  if (expression is PrefixedIdentifier) {
    return expression.identifier.name == 'mounted';
  }
  return false;
}

bool _containsAwait(AstNode node) {
  final visitor = _AwaitFinder();
  node.accept(visitor);
  return visitor.found;
}

bool _usesContextOrSetState(AstNode node) {
  final visitor = _ContextUseFinder();
  node.accept(visitor);
  return visitor.found;
}

/// Finds an `await` anywhere in the statement, without descending into a
/// nested closure (an await inside a separate callback doesn't create an
/// async gap for the statement containing it).
class _AwaitFinder extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitAwaitExpression(AwaitExpression node) {
    found = true;
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
}

/// Finds a `context` reference or a bare `setState(...)` call anywhere in
/// the statement, including inside nested closures (e.g.
/// `setState(() { ... })` itself is the risky call, regardless of what its
/// callback body does).
class _ContextUseFinder extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == 'context') found = true;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    if (node.methodName.name == 'setState' && node.target == null) {
      found = true;
    }
  }
}
