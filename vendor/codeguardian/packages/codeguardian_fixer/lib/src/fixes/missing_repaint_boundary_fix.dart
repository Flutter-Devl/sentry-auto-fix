import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:path/path.dart' as p;

import '../fix.dart';
import '../fix_utils.dart';
import '../unified_diff.dart';

/// Builds a [Fix] that wraps a `Transform(...)`'s `child:` argument in
/// `RepaintBoundary(child: ...)`, for a finding from
/// `MissingRepaintBoundaryRule` (see `codeguardian_rules`).
///
/// Returns `null` for the rule's other flagged shape (`AnimatedBuilder`'s
/// `builder:` return value): locating and rewriting every return path of an
/// arbitrary callback body isn't a safe enough mechanical transform yet, so
/// that case is left for a human to fix.
Fix? buildMissingRepaintBoundaryFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'missing-repaint-boundary') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildMissingRepaintBoundaryFix only handles missing-repaint-boundary '
          'findings',
    );
  }

  final content = File(finding.file).readAsStringSync();
  final result = parseString(content: content, throwIfDiagnostics: false);

  final visitor = _TransformChildFinder(finding.line, result.lineInfo);
  result.unit.accept(visitor);
  final childExpression = visitor.childExpression;
  if (childExpression == null) return null;

  final start = childExpression.offset;
  final end = childExpression.end;
  final newContent = '${content.substring(0, start)}'
      'RepaintBoundary(child: ${content.substring(start, end)})'
      '${content.substring(end)}';

  final relativePath = p.relative(finding.file, from: projectPath);
  final diff = buildUnifiedDiff(
    relativePath,
    splitContentLines(content),
    splitContentLines(newContent),
  );
  return Fix(ruleId: finding.ruleId, file: finding.file, diff: diff);
}

/// Finds the `child:` argument of a `Transform(...)` call on [targetLine].
///
/// Without semantic resolution, `Transform(...)` -- with no explicit
/// `const`/`new`, the idiomatic form -- parses as a bare [MethodInvocation],
/// not an [InstanceCreationExpression]: the parser can't know `Transform`
/// names a class until a later resolution pass rewrites it. Both shapes are
/// handled here; an explicit `const`/`new Transform(...)` is recognized via
/// [InstanceCreationExpression].
class _TransformChildFinder extends RecursiveAstVisitor<void> {
  _TransformChildFinder(this.targetLine, this.lineInfo);

  final int targetLine;
  final LineInfo lineInfo;
  Expression? childExpression;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    super.visitInstanceCreationExpression(node);
    _checkTransform(
      typeName: node.constructorName.type.name2.lexeme,
      arguments: node.argumentList.arguments,
      offset: node.offset,
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    if (node.target != null) return;
    _checkTransform(
      typeName: node.methodName.name,
      arguments: node.argumentList.arguments,
      offset: node.offset,
    );
  }

  void _checkTransform({
    required String typeName,
    required NodeList<Expression> arguments,
    required int offset,
  }) {
    if (childExpression != null) return;
    if (typeName != 'Transform') return;
    if (lineInfo.getLocation(offset).lineNumber != targetLine) return;

    for (final argument in arguments) {
      if (argument is NamedExpression && argument.name.label.name == 'child') {
        childExpression = argument.expression;
        return;
      }
    }
  }
}
