/// CodeGuardian AI — core models, rule interface, and the static analysis
/// engine foundation used by every other package.
///
/// This package is intentionally dependency-light: it depends only on the Dart
/// [`analyzer`](https://pub.dev/packages/analyzer) for resolving source with
/// full type information, plus `meta` and `path`. It contains no Flutter, no
/// AI, and makes no network calls.
library codeguardian_core;

export 'src/analysis_result.dart';
export 'src/models/category.dart';
export 'src/models/finding.dart';
export 'src/models/severity.dart';
export 'src/project_rule.dart';
export 'src/registry.dart';
export 'src/rule.dart';
