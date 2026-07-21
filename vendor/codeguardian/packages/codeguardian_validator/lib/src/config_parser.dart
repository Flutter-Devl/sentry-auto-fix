import 'dart:io';

import 'package:yaml/yaml.dart';

import 'validator_config.dart';

/// Thrown when `codeguardian.yaml` exists but can't be parsed into a
/// [ValidatorConfig] (invalid YAML syntax, or a value of the wrong shape --
/// e.g. `gates.max_high` set to a string).
///
/// This is a distinct type specifically so callers (the CLI) can tell "the
/// config is broken" apart from "the gates failed" -- the former is a tool
/// error, the latter is a normal, expected outcome.
class ConfigParseException implements Exception {
  /// Creates the exception with a human-readable [message].
  const ConfigParseException(this.message);

  /// Explanation of what's wrong with the config.
  final String message;

  @override
  String toString() => 'ConfigParseException: $message';
}

/// Parses `codeguardian.yaml` content into a [ValidatorConfig].
///
/// Expected shape (every section is optional):
/// ```yaml
/// rules:
///   enabled: [missing-const-constructor, unused-import]  # allow-list
///   disabled: [long-method]                              # always off
///
/// exclude:
///   - build/**
///   - "**/*.g.dart"
///
/// gates:
///   max_critical: 0
///   max_high: 5
///   max_medium: 20
///   max_low: 100
///   max_total: 200
///   min_score: 80
/// ```
///
/// Empty or whitespace-only [content] yields [ValidatorConfig]'s defaults
/// (no restrictions, no gates enforced). Throws [ConfigParseException] for
/// anything that doesn't parse as YAML or doesn't match the shape above.
ValidatorConfig parseValidatorConfig(String content) {
  if (content.trim().isEmpty) return const ValidatorConfig();

  final Object? document;
  try {
    document = loadYaml(content);
  } on YamlException catch (error) {
    throw ConfigParseException('codeguardian.yaml is not valid YAML: $error');
  }

  if (document == null) return const ValidatorConfig();
  if (document is! YamlMap) {
    throw ConfigParseException(
      'codeguardian.yaml must be a mapping at the top level, got '
      '${document.runtimeType}',
    );
  }

  return ValidatorConfig(
    rules: _parseRules(document['rules']),
    excludePaths: _stringList(document['exclude'], field: 'exclude') ?? const [],
    gates: _parseGates(document['gates']),
  );
}

/// Reads and parses the `codeguardian.yaml` at [path].
///
/// Returns [ValidatorConfig]'s defaults if the file doesn't exist -- a
/// project with no config file is valid and simply enforces nothing.
/// Throws [ConfigParseException] if it exists but can't be parsed.
Future<ValidatorConfig> loadValidatorConfig(String path) async {
  final file = File(path);
  if (!file.existsSync()) return const ValidatorConfig();
  final content = await file.readAsString();
  return parseValidatorConfig(content);
}

RuleSelection _parseRules(Object? node) {
  if (node == null) return const RuleSelection();
  if (node is! YamlMap) {
    throw ConfigParseException(
      "'rules' must be a mapping with 'enabled'/'disabled' lists, got "
      '${node.runtimeType}',
    );
  }
  final enabled = _stringList(node['enabled'], field: 'rules.enabled');
  final disabled =
      _stringList(node['disabled'], field: 'rules.disabled') ?? const [];
  return RuleSelection(enabled: enabled, disabled: disabled);
}

GateConfig _parseGates(Object? node) {
  if (node == null) return const GateConfig();
  if (node is! YamlMap) {
    throw ConfigParseException(
      "'gates' must be a mapping, got ${node.runtimeType}",
    );
  }
  return GateConfig(
    maxCritical: _asInt(node['max_critical'], field: 'gates.max_critical'),
    maxHigh: _asInt(node['max_high'], field: 'gates.max_high'),
    maxMedium: _asInt(node['max_medium'], field: 'gates.max_medium'),
    maxLow: _asInt(node['max_low'], field: 'gates.max_low'),
    maxTotal: _asInt(node['max_total'], field: 'gates.max_total'),
    minScore: _asNum(node['min_score'], field: 'gates.min_score'),
  );
}

List<String>? _stringList(Object? node, {required String field}) {
  if (node == null) return null;
  if (node is! YamlList) {
    throw ConfigParseException("'$field' must be a list, got ${node.runtimeType}");
  }
  return node.map((entry) {
    if (entry is! String) {
      throw ConfigParseException(
        "'$field' entries must be strings, got ${entry.runtimeType}",
      );
    }
    return entry;
  }).toList();
}

int? _asInt(Object? node, {required String field}) {
  if (node == null) return null;
  if (node is int) return node;
  throw ConfigParseException("'$field' must be an integer, got ${node.runtimeType}");
}

num? _asNum(Object? node, {required String field}) {
  if (node == null) return null;
  if (node is num) return node;
  throw ConfigParseException("'$field' must be a number, got ${node.runtimeType}");
}
