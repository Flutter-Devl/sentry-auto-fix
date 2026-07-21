import 'package:args/command_runner.dart';

import 'ai_command.dart';
import 'analyze_command.dart';
import 'improve_command.dart';
import 'refactor_command.dart';
import 'validate_command.dart';

/// The top-level `codeguardian` command-line runner.
///
/// Registers every subcommand: `analyze`, `validate`, `improve`, `refactor`,
/// and `ai` (with its `configure` subcommand).
class CodeguardianCommandRunner extends CommandRunner<int> {
  /// Creates the runner and registers all subcommands.
  CodeguardianCommandRunner()
      : super(
          'codeguardian',
          'Static analysis for Flutter/Dart projects.',
        ) {
    addCommand(AnalyzeCommand());
    addCommand(ValidateCommand());
    addCommand(ImproveCommand());
    addCommand(RefactorCommand());
    addCommand(AiCommand());
  }
}
