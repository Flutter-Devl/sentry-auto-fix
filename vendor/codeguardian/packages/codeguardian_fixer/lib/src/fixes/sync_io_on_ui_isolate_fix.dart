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

/// Builds a [Fix] that replaces a synchronous `dart:io` call (e.g.
/// `file.readAsStringSync()`) with its async equivalent (`await
/// file.readAsString()`), for a finding from `SyncIoOnUiIsolateRule` (see
/// `codeguardian_rules`).
///
/// Only applies when the call's directly enclosing function/method/closure
/// is already `async`: adding `await` is then a drop-in change with no
/// further edits needed. Returns `null` when the enclosing function isn't
/// async, since making it async could change its signature and ripple out
/// to every caller -- not a change this generator makes unilaterally.
Fix? buildSyncIoOnUiIsolateFix(Finding finding, String projectPath) {
  if (finding.ruleId != 'sync-io-on-ui-isolate') {
    throw ArgumentError.value(
      finding.ruleId,
      'finding.ruleId',
      'buildSyncIoOnUiIsolateFix only handles sync-io-on-ui-isolate findings',
    );
  }

  final content = File(finding.file).readAsStringSync();
  final result = parseString(content: content, throwIfDiagnostics: false);

  final visitor = _SyncCallFinder(finding.line, result.lineInfo);
  result.unit.accept(visitor);
  final call = visitor.match;
  if (call == null || !_isInsideAsyncFunction(call)) return null;

  final methodName = call.methodName;
  final asyncName = methodName.name.replaceFirst(RegExp(r'Sync$'), '');

  final rewrittenCall = content.substring(call.offset, methodName.offset) +
      asyncName +
      content.substring(methodName.end, call.end);
  final newContent = '${content.substring(0, call.offset)}'
      'await $rewrittenCall'
      '${content.substring(call.end)}';

  final relativePath = p.relative(finding.file, from: projectPath);
  final diff = buildUnifiedDiff(
    relativePath,
    splitContentLines(content),
    splitContentLines(newContent),
  );
  return Fix(ruleId: finding.ruleId, file: finding.file, diff: diff);
}

bool _isInsideAsyncFunction(AstNode node) {
  var current = node.parent;
  while (current != null) {
    if (current is FunctionExpression) return current.body.isAsynchronous;
    if (current is MethodDeclaration) return current.body.isAsynchronous;
    if (current is FunctionDeclaration) {
      return current.functionExpression.body.isAsynchronous;
    }
    current = current.parent;
  }
  return false;
}

class _SyncCallFinder extends RecursiveAstVisitor<void> {
  _SyncCallFinder(this.targetLine, this.lineInfo);

  final int targetLine;
  final LineInfo lineInfo;
  MethodInvocation? match;

  static const _syncMethodNames = {
    'readAsStringSync',
    'readAsBytesSync',
    'readAsLinesSync',
    'writeAsStringSync',
    'writeAsBytesSync',
    'deleteSync',
    'createSync',
    'renameSync',
    'copySync',
  };

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    if (match != null) return;
    if (!_syncMethodNames.contains(node.methodName.name)) return;
    if (lineInfo.getLocation(node.offset).lineNumber != targetLine) return;
    match = node;
  }
}
