import 'dart:io';

import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Flags packages declared under `pubspec.yaml`'s `dependencies:` that are
/// never imported anywhere under `lib/`.
///
/// This is a [ProjectRule], not a [CodeGuardianRule]: it needs the whole
/// project's `pubspec.yaml` and every file under `lib/`, not just one
/// resolved file. `dev_dependencies` are out of scope -- dev tools
/// (`build_runner`, lint packages, ...) are routinely never imported in
/// `lib/` by design. `flutter` itself is always exempt.
///
/// Known limitation: a package used only via `pubspec.yaml`'s `flutter:`
/// section (contributing fonts or assets, with no Dart API surface) will be
/// reported even though it is genuinely in use.
class UnusedPluginDependencyRule implements ProjectRule {
  /// Creates the rule.
  const UnusedPluginDependencyRule();

  static final RegExp _packageReferencePattern =
      RegExp(r'''(?:import|export)\s+['"]package:([a-zA-Z0-9_]+)/''');

  static const _alwaysUsed = {'flutter'};

  @override
  String get id => 'unused-plugin-dependency';

  @override
  Future<List<Finding>> check(String projectPath) async {
    final pubspecFile = File(p.join(projectPath, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) return const [];

    final pubspecContent = await pubspecFile.readAsString();
    final document = loadYaml(pubspecContent);
    if (document is! YamlMap) return const [];

    final dependencies = document['dependencies'];
    if (dependencies is! YamlMap) return const [];

    final declared = <String, int>{};
    for (final key in dependencies.nodes.keys) {
      if (key is! YamlNode) continue;
      final name = key.value;
      if (name is! String || _alwaysUsed.contains(name)) continue;
      declared[name] = key.span.start.line + 1;
    }
    if (declared.isEmpty) return const [];

    final libDir = Directory(p.join(projectPath, 'lib'));
    if (!libDir.existsSync()) return const [];

    final imported = <String>{};
    await for (final entity in libDir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final content = await entity.readAsString();
      for (final match in _packageReferencePattern.allMatches(content)) {
        imported.add(match.group(1)!);
      }
    }

    final pubspecLines = pubspecContent.split('\n');
    final findings = <Finding>[];
    for (final entry in declared.entries) {
      if (imported.contains(entry.key)) continue;

      final line = entry.value;
      findings.add(Finding(
        ruleId: 'unused-plugin-dependency',
        category: Category.performance,
        severity: Severity.low,
        file: pubspecFile.path,
        line: line,
        column: 1,
        message: "'${entry.key}' is declared as a dependency in "
            'pubspec.yaml but is never imported anywhere under lib/; '
            'consider removing it to reduce build size and dependency risk.',
        snippet: line - 1 < pubspecLines.length
            ? pubspecLines[line - 1].trim()
            : '',
      ));
    }
    return findings;
  }
}
