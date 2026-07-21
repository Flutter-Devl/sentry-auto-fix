import 'dart:io';

import 'package:codeguardian_cli/codeguardian_cli.dart' as cli;

Future<void> main(List<String> arguments) async {
  exitCode = await cli.run(arguments);
}
