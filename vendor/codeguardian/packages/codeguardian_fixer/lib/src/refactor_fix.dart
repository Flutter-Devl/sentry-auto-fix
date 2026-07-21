import 'dart:io';

import 'package:path/path.dart' as p;

import 'fix.dart';
import 'fix_utils.dart';
import 'unified_diff.dart';

/// Builds a [Fix] that replaces [file]'s entire contents with
/// [refactoredContent] -- the whole-file rewrite an AI provider produced for a
/// refactoring finding (see `codeguardian_ai`'s `AiProvider.suggestRefactor`).
///
/// Returns `null` when [refactoredContent] is identical to what's on disk (an
/// AI provider that declined to change anything), so callers don't queue up a
/// no-op empty diff for [applyFixes] to choke on.
///
/// [confidence] is carried straight through to the resulting [Fix]. Unlike the
/// deterministic fix generators in this package -- which leave [Fix.confidence]
/// at its `1.0` default because they're derived mechanically -- a refactor fix
/// is only as trustworthy as the model that produced it, which is exactly the
/// sub-`1.0` case [Fix.confidence] was designed for.
Fix? buildRefactorFix({
  required String file,
  required String projectPath,
  required String refactoredContent,
  required double confidence,
  String ruleId = 'refactor',
}) {
  final oldContent = File(file).readAsStringSync();
  if (refactoredContent == oldContent) return null;

  final relativePath = p.relative(file, from: projectPath);
  final diff = buildUnifiedDiff(
    relativePath,
    splitContentLines(oldContent),
    splitContentLines(refactoredContent),
  );
  if (diff.isEmpty) return null;

  return Fix(
    ruleId: ruleId,
    file: file,
    diff: diff,
    confidence: confidence,
  );
}
