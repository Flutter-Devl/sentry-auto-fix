import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:codeguardian_ai/codeguardian_ai.dart';
import 'package:path/path.dart' as p;

/// The `ai configure` command: selects an AI provider and, for `anthropic`,
/// which environment variable holds the API key.
///
/// The key itself is **never** accepted as a CLI argument or written to
/// disk -- only the environment variable *name* is persisted. The actual
/// key is read from that environment variable fresh at analysis time (see
/// `createAiProvider`), so it never appears in shell history, process
/// listings, or `codeguardian-ai-config.json`.
class AiConfigureCommand extends Command<int> {
  /// Creates the command and registers its options.
  AiConfigureCommand() {
    argParser
      ..addOption(
        'path',
        defaultsTo: '.',
        help: 'Project directory to write the AI config file into.',
      )
      ..addOption(
        'provider',
        abbr: 'p',
        allowed: const ['anthropic', 'none'],
        defaultsTo: 'anthropic',
        help: '"anthropic" to enable AI-backed fix suggestions, or "none" '
            'for offline mode (no code is ever sent externally).',
      )
      ..addOption(
        'api-key-env',
        defaultsTo: 'ANTHROPIC_API_KEY',
        help: 'Name of the environment variable holding the Anthropic API '
            'key. Only the variable name is saved -- never the key value '
            'itself. Ignored when --provider=none.',
      )
      ..addOption(
        'model',
        defaultsTo: defaultAnthropicModel,
        help: 'Anthropic model id to request. Ignored when --provider=none.',
      );
  }

  @override
  String get name => 'configure';

  @override
  String get description =>
      'Select an AI provider (or disable AI entirely) and, for a real '
      'provider, which environment variable holds its API key.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final path = results['path'] as String;
    final provider = results['provider'] as String;
    final apiKeyEnv = results['api-key-env'] as String;
    final model = results['model'] as String;

    final directory = Directory(path);
    if (!directory.existsSync()) {
      stderr.writeln("Path not found: '$path'");
      return 66;
    }

    if (provider == 'anthropic') {
      final apiKey = Platform.environment[apiKeyEnv];
      if (apiKey == null || apiKey.isEmpty) {
        stderr.writeln(
          "Environment variable '$apiKeyEnv' is not set in this shell. "
          'Export it before using the anthropic provider, e.g.:\n'
          '  export $apiKeyEnv="your-api-key"\n'
          'Configuration was not saved.',
        );
        return 64;
      }
    }

    final config = AiConfig(
      provider: provider,
      apiKeyEnvVar: provider == 'anthropic' ? apiKeyEnv : null,
      model: provider == 'anthropic' ? model : null,
    );

    final configFile = File(p.join(directory.absolute.path, aiConfigFileName));
    writeAiConfig(configFile, config);

    // ignore: avoid_print
    print(
      provider == 'anthropic'
          ? 'AI provider configured: anthropic (model: $model).\n'
              "The API key is read from '$apiKeyEnv' at analysis time -- it "
              'is never written to disk.\n'
              'Saved to ${configFile.path}'
          : 'AI provider configured: none (offline mode -- no code is ever '
              'sent externally).\n'
              'Saved to ${configFile.path}',
    );

    return 0;
  }
}
