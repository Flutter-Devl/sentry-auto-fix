/// CodeGuardian AI - command-line interface entry point.
///
/// Implements `analyze` (report findings, optionally applying fixes and
/// publishing/launching the dashboard), `validate` (evaluate quality gates,
/// exiting 0/1/2), `refactor` (AI-assisted rewrites), and `improve` (the full
/// analyze → fix → validate → report pipeline).
library codeguardian_cli;

import 'dart:io';

import 'package:args/command_runner.dart';

import 'src/codeguardian_command_runner.dart';

export 'src/analyze_command.dart';
export 'src/codeguardian_command_runner.dart';
export 'src/improve_command.dart';
export 'src/module_discovery.dart';
export 'src/refactor_command.dart';
export 'src/validate_command.dart';

/// Parses [arguments] and runs the matching command, returning the process
/// exit code.
///
/// Any exception a command doesn't handle itself is caught here and mapped
/// to exit code `2` ("tool error") -- this is deliberately a distinct
/// fallback from [ValidateCommand]'s own `0`/`1`/`2` exit codes, so an
/// unexpected crash can never be silently reported as exit `1` (a gate
/// failure) or `0` (success). [UsageException] (malformed CLI arguments) is
/// handled separately, matching how `dart`/`pub`-style tools distinguish
/// "you invoked this wrong" (64) from "the tool broke" (2).
Future<int> run(List<String> arguments) async {
  final runner = CodeguardianCommandRunner();
  try {
    return await runner.run(arguments) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(error.usage);
    return 64;
  } catch (error, stackTrace) {
    stderr.writeln('codeguardian: unexpected error: $error');
    stderr.writeln(stackTrace);
    return 2;
  }
}
