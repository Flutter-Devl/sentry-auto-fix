import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags synchronous `dart:io` file operations (`readAsStringSync`,
/// `writeAsBytesSync`, ...), which block the entire isolate -- including the
/// UI thread in a Flutter app -- until the operation completes.
///
/// Only calls resolved to `dart:io`'s `File`, `Directory`,
/// `FileSystemEntity`, or `RandomAccessFile` are flagged, so a user-defined
/// method that merely happens to share a name (e.g. a custom `saveSync()`)
/// isn't.
class SyncIoOnUiIsolateRule implements CodeGuardianRule {
  /// Creates the rule.
  const SyncIoOnUiIsolateRule();

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

  static const _dartIoClassNames = {
    'File',
    'Directory',
    'FileSystemEntity',
    'RandomAccessFile',
  };

  @override
  String get id => 'sync-io-on-ui-isolate';

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
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);

    final methodName = node.methodName.name;
    if (!SyncIoOnUiIsolateRule._syncMethodNames.contains(methodName)) return;
    if (!_isDartIoTarget(node)) return;

    final location = unit.lineInfo.getLocation(node.offset);
    findings.add(Finding(
      ruleId: 'sync-io-on-ui-isolate',
      category: Category.performance,
      severity: Severity.high,
      file: unit.path,
      line: location.lineNumber,
      column: location.columnNumber,
      message: "'$methodName' blocks the entire isolate -- including the UI "
          'thread in a Flutter app -- until it completes; use the async '
          "equivalent (drop the 'Sync' suffix and await it) instead.",
      snippet: lineSnippet(unit, location.lineNumber),
    ));
  }

  bool _isDartIoTarget(MethodInvocation node) {
    // Use `enclosingElement` (not `enclosingElement3`) so the rule compiles
    // against the whole declared `analyzer: ^6.4.0` range; `enclosingElement3`
    // only exists in analyzer >= 6.7.0, but consumers (e.g. Flutter apps) can
    // legitimately resolve analyzer to 6.4.x.
    // ignore: deprecated_member_use
    final enclosing = node.methodName.staticElement?.enclosingElement;
    if (enclosing is! InterfaceElement) return false;
    if (!SyncIoOnUiIsolateRule._dartIoClassNames.contains(enclosing.name)) {
      return false;
    }
    return enclosing.library.source.uri.toString() == 'dart:io';
  }
}
