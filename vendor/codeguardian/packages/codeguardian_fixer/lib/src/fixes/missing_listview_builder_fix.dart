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

/// Builds a [Fix] that rewrites `ListView(children: X.map((item) => body)
/// .toList())` into `ListView.builder(...)`, for a finding from
/// `MissingListViewBuilderRule` (see `codeguardian_rules`).
///
/// Only applies when `X` is a **simple identifier** (a plain variable
/// reference), not an arbitrary expression: `ListView.builder`'s
/// `itemBuilder` re-evaluates `X.elementAt(index)`/`X.length` for every
/// visible item on every build, so if `X` were, say, a getter that
/// recomputes an expensive value, rewriting to `.builder` would silently
/// change the performance characteristics the rule is trying to fix. For
/// anything other than a bare variable, this returns `null` rather than
/// risk that.
///
/// `.elementAt(index)`/`.length` (not `X[index]`) are used deliberately so
/// the rewrite works whether `X` is a `List`, `Set`, or any other
/// `Iterable`.
Fix? buildMissingListViewBuilderFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'missing-listview-builder') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildMissingListViewBuilderFix only handles missing-listview-builder '
          'findings',
    );
  }

  final content = File(finding.file).readAsStringSync();
  final result = parseString(content: content, throwIfDiagnostics: false);

  final visitor = _ListViewFinder(finding.line, result.lineInfo, content);
  result.unit.accept(visitor);
  final match = visitor.match;
  if (match == null) return null;

  final indent = leadingWhitespaceOf(
    content.split('\n')[finding.line - 1],
  );
  final replacement = 'ListView.builder(\n'
      '$indent  itemCount: ${match.iterableName}.length,\n'
      '$indent  itemBuilder: (context, index) {\n'
      '$indent    final ${match.paramName} = '
      '${match.iterableName}.elementAt(index);\n'
      '$indent    return ${match.bodyText};\n'
      '$indent  },\n'
      '$indent)';

  final newContent = '${content.substring(0, match.start)}'
      '$replacement'
      '${content.substring(match.end)}';

  final relativePath = p.relative(finding.file, from: projectPath);
  final diff = buildUnifiedDiff(
    relativePath,
    splitContentLines(content),
    splitContentLines(newContent),
  );
  return Fix(ruleId: finding.ruleId, file: finding.file, diff: diff);
}

class _GeneratedListMatch {
  _GeneratedListMatch({
    required this.start,
    required this.end,
    required this.iterableName,
    required this.paramName,
    required this.bodyText,
  });

  final int start;
  final int end;
  final String iterableName;
  final String paramName;
  final String bodyText;
}

/// Finds a `ListView(children: ...)` call on [targetLine].
///
/// Without semantic resolution, `ListView(...)` -- with no explicit
/// `const`/`new`, the idiomatic form -- parses as a bare [MethodInvocation],
/// not an [InstanceCreationExpression]: the parser can't know `ListView`
/// names a class until a later resolution pass rewrites it. Both shapes are
/// handled here; an explicit `const`/`new ListView(...)` is recognized via
/// [InstanceCreationExpression].
class _ListViewFinder extends RecursiveAstVisitor<void> {
  _ListViewFinder(this.targetLine, this.lineInfo, this.content);

  final int targetLine;
  final LineInfo lineInfo;
  final String content;
  _GeneratedListMatch? match;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    super.visitInstanceCreationExpression(node);
    if (node.constructorName.name != null) return;
    _checkListView(
      typeName: node.constructorName.type.name2.lexeme,
      arguments: node.argumentList.arguments,
      offset: node.offset,
      end: node.end,
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    if (node.target != null) return;
    _checkListView(
      typeName: node.methodName.name,
      arguments: node.argumentList.arguments,
      offset: node.offset,
      end: node.end,
    );
  }

  void _checkListView({
    required String typeName,
    required NodeList<Expression> arguments,
    required int offset,
    required int end,
  }) {
    if (match != null) return;
    if (typeName != 'ListView') return;
    if (lineInfo.getLocation(offset).lineNumber != targetLine) return;

    for (final argument in arguments) {
      if (argument is! NamedExpression) continue;
      if (argument.name.label.name != 'children') continue;

      final generated = _asSimpleMapToList(argument.expression, content);
      if (generated == null) return;

      match = _GeneratedListMatch(
        start: offset,
        end: end,
        iterableName: generated.iterableName,
        paramName: generated.paramName,
        bodyText: generated.bodyText,
      );
      return;
    }
  }
}

class _MapToList {
  _MapToList({
    required this.iterableName,
    required this.paramName,
    required this.bodyText,
  });

  final String iterableName;
  final String paramName;
  final String bodyText;
}

/// Recognizes `<simpleIdentifier>.map((<param>) => <body>).toList()`,
/// returning `null` for anything else (block-bodied lambdas, a non-identifier
/// iterable target, more than one lambda parameter, ...).
_MapToList? _asSimpleMapToList(Expression expression, String content) {
  if (expression is! MethodInvocation) return null;
  if (expression.methodName.name != 'toList') return null;

  final target = expression.target;
  if (target is! MethodInvocation) return null;
  if (target.methodName.name != 'map') return null;

  final iterable = target.target;
  if (iterable is! SimpleIdentifier) return null;

  final mapArguments = target.argumentList.arguments;
  if (mapArguments.length != 1) return null;
  final lambda = mapArguments.first;
  if (lambda is! FunctionExpression) return null;

  final parameters = lambda.parameters?.parameters;
  if (parameters == null || parameters.length != 1) return null;
  final parameter = parameters.first;
  if (parameter is! SimpleFormalParameter) return null;
  final paramName = parameter.name?.lexeme;
  if (paramName == null) return null;

  final body = lambda.body;
  if (body is! ExpressionFunctionBody) return null;

  return _MapToList(
    iterableName: iterable.name,
    paramName: paramName,
    bodyText: content.substring(body.expression.offset, body.expression.end),
  );
}
