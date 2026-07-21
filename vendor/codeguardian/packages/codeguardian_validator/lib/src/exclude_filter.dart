import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Removes findings whose file matches any of [excludeGlobs], as of a
/// project rooted at [projectPath].
///
/// Patterns are matched against the finding's file path relative to
/// [projectPath] (e.g. `build/**`, `**/*.g.dart`), so they read the same
/// whether the project is checked out at `/home/alice/app` or
/// `/ci/workspace/app`.
List<Finding> filterExcluded(
  List<Finding> findings,
  List<String> excludeGlobs, {
  required String projectPath,
}) {
  if (excludeGlobs.isEmpty) return findings;

  final globs = excludeGlobs.map((pattern) => Glob(pattern)).toList();
  return findings.where((finding) {
    final relativePath = p.relative(finding.file, from: projectPath);
    return !globs.any((glob) => glob.matches(relativePath));
  }).toList();
}
