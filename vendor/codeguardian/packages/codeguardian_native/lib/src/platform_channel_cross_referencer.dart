import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:path/path.dart' as p;

/// Cross-references Flutter platform channels (`MethodChannel`,
/// `EventChannel`) declared in Dart against their native-side
/// registration, and flags a common class of native handler bug.
///
/// **This rule is pattern-based, not a full data-flow or cross-language AST
/// analysis.** There is no Kotlin/Swift parser available here, so the native
/// side is matched with regular expressions over raw source text. This
/// means:
///  * A channel name built from anything other than a single string literal
///    (string interpolation, a constant reference, concatenation, ...) is
///    invisible to this rule on either side -- both the Dart scan and the
///    native scan only recognize literal channel-name strings.
///  * "No native handler found" means the exact channel-name string wasn't
///    found anywhere in any `.kt`/`.swift` file under `android/`/`ios/` --
///    not that the channel definitely isn't handled (e.g. a name built at
///    runtime on the native side, or registered in a different platform
///    folder layout, will be a false positive for this finding).
///  * "Argument used without validation" is a proximity heuristic (does an
///    argument-extraction line get followed within a short window by a
///    file/query-construction line with no validation keyword in between),
///    not real taint tracking. Validation performed via a helper function
///    defined elsewhere, or argument use guarded far outside the lookahead
///    window, will be a false negative. Treat every finding from this rule
///    as a prompt to look at the code, not as a proven vulnerability.
class PlatformChannelCrossReferencer implements ProjectRule {
  /// Creates the cross-referencer.
  ///
  /// [argumentSinkLookaheadLines] bounds how many lines past an
  /// argument-extraction line are scanned for a risky sink before giving up.
  const PlatformChannelCrossReferencer({this.argumentSinkLookaheadLines = 15});

  /// How many lines past an argument-extraction line to scan for a risky
  /// file-path/query sink.
  final int argumentSinkLookaheadLines;

  @override
  String get id => 'platform-channel-cross-reference';

  @override
  Future<List<Finding>> check(String projectPath) async {
    final libDir = Directory(p.join(projectPath, 'lib'));
    if (!libDir.existsSync()) return const [];

    final channels = await _collectChannelUsages(libDir);
    final nativeFiles = await _collectNativeFiles(projectPath);

    final findings = <Finding>[];
    if (channels.isNotEmpty) {
      findings.addAll(_checkMissingHandlers(channels, nativeFiles));
    }
    if (nativeFiles.isNotEmpty) {
      findings.addAll(_checkUnvalidatedArgumentUsage(nativeFiles));
    }
    return findings;
  }

  Future<List<_ChannelUsage>> _collectChannelUsages(Directory libDir) async {
    final usages = <_ChannelUsage>[];

    await for (final entity in libDir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final content = await entity.readAsString();
      final result = parseString(
        content: content,
        path: entity.path,
        throwIfDiagnostics: false,
      );

      final visitor = _ChannelVisitor();
      result.unit.accept(visitor);

      for (final raw in visitor.usages) {
        final location = result.lineInfo.getLocation(raw.offset);
        usages.add(_ChannelUsage(
          name: raw.name,
          kind: raw.kind,
          file: entity.path,
          line: location.lineNumber,
          methods: raw.methods,
        ));
      }
    }

    return usages;
  }

  Future<Map<String, String>> _collectNativeFiles(String projectPath) async {
    final files = <String, String>{};

    for (final platformRoot in ['android', 'ios']) {
      final dir = Directory(p.join(projectPath, platformRoot));
      if (!dir.existsSync()) continue;

      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.kt') && !entity.path.endsWith('.swift')) {
          continue;
        }
        files[entity.path] = await entity.readAsString();
      }
    }

    return files;
  }

  List<Finding> _checkMissingHandlers(
    List<_ChannelUsage> channels,
    Map<String, String> nativeFiles,
  ) {
    final findings = <Finding>[];
    final reported = <String>{};

    for (final channel in channels) {
      if (!reported.add(channel.name)) continue;

      final hasNativeHandler = nativeFiles.values.any(
        (content) =>
            content.contains('"${channel.name}"') ||
            content.contains("'${channel.name}'"),
      );
      if (hasNativeHandler) continue;

      final lines = File(channel.file).readAsLinesSync();
      final methodsNote = channel.methods.isEmpty
          ? ''
          : ' (methods: ${channel.methods.join(', ')})';

      findings.add(Finding(
        ruleId: 'platform-channel-cross-reference',
        category: Category.security,
        severity: Severity.medium,
        file: channel.file,
        line: channel.line,
        column: 1,
        message: "${channel.kind} '${channel.name}'$methodsNote is used "
            'from Dart but no matching native handler string was found '
            'under android/ or ios/; verify a handler is registered on '
            "both platforms, or that this channel name isn't a typo. "
            '(Pattern-based: a native-side name built dynamically rather '
            "than as a literal won't be detected.)",
        snippet: channel.line - 1 < lines.length
            ? lines[channel.line - 1].trim()
            : '',
        masvsId: 'MASVS-PLATFORM-2',
      ));
    }

    return findings;
  }

  List<Finding> _checkUnvalidatedArgumentUsage(
    Map<String, String> nativeFiles,
  ) {
    final findings = <Finding>[];

    for (final entry in nativeFiles.entries) {
      final path = entry.key;
      final isSwift = path.endsWith('.swift');
      final lines = entry.value.split('\n');

      for (var i = 0; i < lines.length; i++) {
        if (!_looksLikeArgumentExtraction(lines[i], isSwift)) continue;

        final windowEnd = i + argumentSinkLookaheadLines < lines.length
            ? i + argumentSinkLookaheadLines
            : lines.length - 1;

        for (var j = i; j <= windowEnd; j++) {
          if (!_looksLikeRiskySink(lines[j])) continue;
          if (lines[j].contains('?')) break; // parameterized placeholder
          final window = lines.sublist(i, j + 1).join('\n');
          if (_containsValidationSignal(window)) break;

          final isPathSink = _pathSinkPattern.hasMatch(lines[j]);
          findings.add(Finding(
            ruleId: 'platform-channel-cross-reference',
            category: Category.security,
            severity: Severity.high,
            file: path,
            line: j + 1,
            column: 1,
            message: 'A platform-channel argument extracted at line '
                '${i + 1} appears to be used directly in '
                '${isPathSink ? 'file-path construction' : 'query construction'} '
                'without an obvious validation/sanitization step in '
                'between; validate or canonicalize untrusted input before '
                'using it in a file path or query. (Best-effort pattern '
                'match over a fixed line window, not data-flow analysis -- '
                'verify manually.)',
            snippet: lines[j].trim(),
            cweId: isPathSink ? 'CWE-22' : 'CWE-89',
            masvsId: 'MASVS-CODE-4',
          ));
          break;
        }
      }
    }

    return findings;
  }

  static final _kotlinArgumentPattern = RegExp(r'call\.argument');
  static final _swiftArgumentPattern = RegExp(r'call\.arguments');

  bool _looksLikeArgumentExtraction(String line, bool isSwift) =>
      isSwift
          ? _swiftArgumentPattern.hasMatch(line)
          : _kotlinArgumentPattern.hasMatch(line);

  static final _pathSinkPattern = RegExp(
    r'File\(|FileInputStream\(|FileOutputStream\(|openFileInput\(|'
    r'openFileOutput\(|Uri\.parse\(|URL\(fileURLWithPath|'
    r'FileManager\.default|contentsOfFile',
  );

  static final _querySinkPattern = RegExp(
    r'rawQuery\(|execSQL\(|SELECT |INSERT INTO|UPDATE .*SET|DELETE FROM',
    caseSensitive: false,
  );

  bool _looksLikeRiskySink(String line) =>
      _pathSinkPattern.hasMatch(line) || _querySinkPattern.hasMatch(line);

  static final _validationPattern = RegExp(
    r'sanitiz|validat|isValid|canonicalPath|normalize|contains\("\.\."\)|'
    r'startsWith\(|\.replace\(|Regex\(|\.matches\(',
    caseSensitive: false,
  );

  bool _containsValidationSignal(String text) =>
      _validationPattern.hasMatch(text);
}

class _ChannelUsage {
  _ChannelUsage({
    required this.name,
    required this.kind,
    required this.file,
    required this.line,
    required this.methods,
  });

  final String name;
  final String kind;
  final String file;
  final int line;
  final Set<String> methods;
}

class _RawChannelUsage {
  _RawChannelUsage({required this.name, required this.kind, required this.offset});

  final String name;
  final String kind;
  final int offset;
  final Set<String> methods = {};
}

/// Walks a single Dart file's (unresolved) AST for `MethodChannel`/
/// `EventChannel` instantiations with a literal channel-name argument, and
/// -- best-effort, same-file only -- the `invokeMethod` calls made against a
/// simple variable holding one of those channels.
///
/// Without semantic resolution, `MethodChannel('name')` -- with no explicit
/// `const`/`new`, which is the idiomatic Flutter form
/// (`static const _channel = MethodChannel('name');`) -- parses as a bare
/// [MethodInvocation], not an [InstanceCreationExpression]: the parser can't
/// know `MethodChannel` names a class until a later resolution pass rewrites
/// it. Both shapes are handled here so the common case isn't missed; an
/// explicit `const MethodChannel(...)`/`new MethodChannel(...)` is also
/// recognized via [InstanceCreationExpression].
class _ChannelVisitor extends RecursiveAstVisitor<void> {
  final List<_RawChannelUsage> usages = [];
  final Map<String, _RawChannelUsage> _byVariableName = {};

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    super.visitInstanceCreationExpression(node);

    _recordIfChannelConstruction(
      typeName: node.constructorName.type.name2.lexeme,
      arguments: node.argumentList.arguments,
      offset: node.offset,
      parent: node.parent,
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);

    if (node.methodName.name == 'invokeMethod') {
      _recordInvokeMethod(node);
      return;
    }

    if (node.target == null) {
      _recordIfChannelConstruction(
        typeName: node.methodName.name,
        arguments: node.argumentList.arguments,
        offset: node.offset,
        parent: node.parent,
      );
    }
  }

  void _recordIfChannelConstruction({
    required String typeName,
    required NodeList<Expression> arguments,
    required int offset,
    required AstNode? parent,
  }) {
    if (typeName != 'MethodChannel' && typeName != 'EventChannel') return;
    if (arguments.isEmpty) return;
    final first = arguments.first;
    if (first is! SimpleStringLiteral) return;

    final usage = _RawChannelUsage(
      name: first.value,
      kind: typeName,
      offset: offset,
    );
    usages.add(usage);

    if (parent is VariableDeclaration) {
      _byVariableName[parent.name.lexeme] = usage;
    }
  }

  void _recordInvokeMethod(MethodInvocation node) {
    final target = node.target;
    if (target is! SimpleIdentifier) return;

    final usage = _byVariableName[target.name];
    if (usage == null) return;

    final arguments = node.argumentList.arguments;
    if (arguments.isEmpty) return;
    final methodArgument = arguments.first;
    if (methodArgument is SimpleStringLiteral) {
      usage.methods.add(methodArgument.value);
    }
  }
}
