import 'package:args/command_runner.dart';

import 'ai_configure_command.dart';

/// The `ai` command group. Currently has one subcommand, `configure`; the
/// runner requires a subcommand to be named (there's no bare `codeguardian
/// ai` behavior).
class AiCommand extends Command<int> {
  /// Creates the command and registers its subcommands.
  AiCommand() {
    addSubcommand(AiConfigureCommand());
  }

  @override
  String get name => 'ai';

  @override
  String get description => 'Configure and manage AI-backed fix suggestions.';
}
