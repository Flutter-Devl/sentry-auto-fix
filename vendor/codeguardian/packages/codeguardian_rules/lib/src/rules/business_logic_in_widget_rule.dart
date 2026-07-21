import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';

import 'rule_utils.dart';

/// Flags business logic embedded directly inside a widget class -- network
/// calls, file/directory IO, JSON parsing, or persistent storage access --
/// which belongs in a service or repository the widget delegates to, not in
/// the widget itself.
///
/// A "widget class" is recognised structurally, the same way
/// [ExpensiveBuildMethodRule] recognises a build method: by superclass name
/// (`StatelessWidget`, `StatefulWidget`, or `State`), so this works without
/// depending on Flutter or resolving `Widget` itself.
///
/// Detected as business logic:
///  * network: `http.get`/`post`/`put`/`delete`/`patch`, or any method call
///    on a `Dio` instance whose name is one of those verbs;
///  * persistence: `SharedPreferences.getInstance(...)`;
///  * serialization: `jsonDecode(...)`/`jsonEncode(...)` and
///    `json.decode(...)`/`json.encode(...)`;
///  * IO: constructing a `File(...)`, `Directory(...)`, or `Dio(...)`.
///
/// Each offending call site is reported separately so a refactor can address
/// them one by one.
class BusinessLogicInWidgetRule implements CodeGuardianRule {
  /// Creates the rule.
  const BusinessLogicInWidgetRule();

  @override
  String get id => 'business-logic-in-widget';

  @override
  List<Finding> check(ResolvedUnitResult unit) {
    final visitor = _ClassVisitor(unit);
    unit.unit.accept(visitor);
    return visitor.findings;
  }
}

const _widgetSuperclasses = {'StatelessWidget', 'StatefulWidget', 'State'};

class _ClassVisitor extends RecursiveAstVisitor<void> {
  _ClassVisitor(this.unit);

  final ResolvedUnitResult unit;
  final List<Finding> findings = [];

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    super.visitClassDeclaration(node);

    final superName = node.extendsClause?.superclass.name2.lexeme;
    if (superName == null || !_widgetSuperclasses.contains(superName)) return;

    final visitor = _BusinessLogicVisitor(unit);
    node.accept(visitor);
    findings.addAll(visitor.findings);
  }
}

class _BusinessLogicVisitor extends RecursiveAstVisitor<void> {
  _BusinessLogicVisitor(this.unit);

  final ResolvedUnitResult unit;
  final List<Finding> findings = [];

  static const _networkVerbs = {'get', 'post', 'put', 'delete', 'patch'};
  static const _jsonFunctions = {'jsonDecode', 'jsonEncode'};
  static const _ioTypes = {'File', 'Directory', 'Dio'};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);

    final name = node.methodName.name;
    final target = node.target;

    // http.get(...), http.post(...), and the rest of the verb set.
    final isHttpCall = target is SimpleIdentifier &&
        target.name == 'http' &&
        _networkVerbs.contains(name);

    // json.decode(...) / json.encode(...).
    final isJsonCodecCall = (name == 'decode' || name == 'encode') &&
        target is SimpleIdentifier &&
        target.name == 'json';

    // SharedPreferences.getInstance(...).
    final isPrefsCall = name == 'getInstance' &&
        target is SimpleIdentifier &&
        target.name == 'SharedPreferences';

    if (isHttpCall) {
      _report(node.offset, 'A network call (http.$name(...))');
    } else if (_jsonFunctions.contains(name) || isJsonCodecCall) {
      _report(node.offset, 'JSON serialization ($name(...))');
    } else if (isPrefsCall) {
      _report(node.offset, 'Persistent storage access (SharedPreferences)');
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    super.visitInstanceCreationExpression(node);

    final typeName = node.constructorName.type.name2.lexeme;
    if (_ioTypes.contains(typeName)) {
      _report(node.offset, 'IO/client construction ($typeName(...))');
    }
  }

  void _report(int offset, String what) {
    final location = unit.lineInfo.getLocation(offset);
    findings.add(Finding(
      ruleId: 'business-logic-in-widget',
      category: Category.style,
      severity: Severity.medium,
      file: unit.path,
      line: location.lineNumber,
      column: location.columnNumber,
      message: '$what runs inside a widget class. Move this logic into a '
          'dedicated service or repository the widget delegates to, so the '
          'widget stays focused on presentation and the logic stays testable '
          'in isolation.',
      snippet: lineSnippet(unit, location.lineNumber),
    ));
  }
}
