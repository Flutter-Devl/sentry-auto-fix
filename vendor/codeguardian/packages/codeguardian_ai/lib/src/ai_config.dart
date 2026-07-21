import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import 'ai_provider.dart';
import 'anthropic_ai_provider.dart';
import 'noop_ai_provider.dart';

/// The filename `codeguardian ai configure` writes, alongside
/// `codeguardian.yaml` and `codeguardian-baseline.json` in a project root.
const aiConfigFileName = 'codeguardian-ai-config.json';

/// Persisted AI provider configuration, written by `codeguardian ai
/// configure` and read whenever a fix suggestion is requested.
///
/// Deliberately never carries the API key itself -- only which environment
/// variable to read it from at call time (see [createAiProvider]).
@immutable
class AiConfig {
  /// Creates a config. [provider] is `'anthropic'` or `'none'`.
  const AiConfig({required this.provider, this.apiKeyEnvVar, this.model});

  /// Which provider to use: `'anthropic'` or `'none'` (offline).
  final String provider;

  /// Name of the environment variable holding the API key, e.g.
  /// `ANTHROPIC_API_KEY`. Never the key itself.
  final String? apiKeyEnvVar;

  /// Model id to request, e.g. `claude-opus-4-8`.
  final String? model;

  /// Decodes a config from its on-disk JSON representation.
  factory AiConfig.fromJson(Map<String, dynamic> json) => AiConfig(
        provider: json['provider'] as String,
        apiKeyEnvVar: json['apiKeyEnvVar'] as String?,
        model: json['model'] as String?,
      );

  /// The on-disk JSON representation. Contains no secret values.
  Map<String, dynamic> toJson() => {
        'provider': provider,
        if (apiKeyEnvVar != null) 'apiKeyEnvVar': apiKeyEnvVar,
        if (model != null) 'model': model,
      };
}

/// Writes [config] to [file] as pretty-printed JSON.
void writeAiConfig(File file, AiConfig config) {
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config.toJson()));
}

/// Reads a config from [file], or returns `null` if it doesn't exist.
AiConfig? readAiConfig(File file) {
  if (!file.existsSync()) return null;
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return AiConfig.fromJson(decoded);
}

/// Builds the [AiProvider] described by [config], resolving the API key
/// from [environment] (defaults to the real process environment) at call
/// time -- the key is never read from, or written to, the config file
/// itself.
///
/// Falls back to [NoOpAiProvider] whenever AI can't actually run: no
/// config, `provider: 'none'`, or the configured environment variable isn't
/// set. This means a caller can always just call `suggestFix` without
/// checking whether AI is "available" first.
AiProvider createAiProvider(AiConfig? config, {Map<String, String>? environment}) {
  if (config == null || config.provider == 'none') return const NoOpAiProvider();

  final env = environment ?? Platform.environment;
  final envVar = config.apiKeyEnvVar ?? 'ANTHROPIC_API_KEY';
  final apiKey = env[envVar];
  if (apiKey == null || apiKey.isEmpty) return const NoOpAiProvider();

  return AnthropicAiProvider(
    apiKey: apiKey,
    model: config.model ?? defaultAnthropicModel,
  );
}
