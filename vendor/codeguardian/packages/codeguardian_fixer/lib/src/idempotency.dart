import 'package:meta/meta.dart';

import 'apply_fixes.dart';
import 'fix.dart';

/// The outcome of a [checkIdempotency] run.
@immutable
class IdempotencyCheckResult {
  /// Creates a result.
  const IdempotencyCheckResult({
    required this.firstPassFixCount,
    required this.secondPassFixCount,
  });

  /// How many fixes the first pass found (and applied).
  final int firstPassFixCount;

  /// How many fixes a second, identical pass found against the now-fixed
  /// project. A correct, idempotent fix should leave nothing left to fix.
  final int secondPassFixCount;

  /// Whether the second pass found zero additional fixes.
  ///
  /// `true` when [firstPassFixCount] is also `0` (nothing to fix at all is
  /// trivially idempotent).
  bool get isIdempotent => secondPassFixCount == 0;

  @override
  String toString() => 'IdempotencyCheckResult(first: $firstPassFixCount, '
      'second: $secondPassFixCount, idempotent: $isIdempotent)';
}

/// Thrown when [checkIdempotency] can't complete because applying the first
/// pass of fixes failed.
class IdempotencyCheckException implements Exception {
  /// Creates the exception.
  const IdempotencyCheckException(this.failures);

  /// The fixes that failed to apply, from [ApplyFixesResult.failed].
  final List<FixFailure> failures;

  @override
  String toString() =>
      'IdempotencyCheckException: ${failures.length} fix(es) failed to '
      'apply: ${failures.join(', ')}';
}

/// Proves a fix-generation strategy is idempotent: applying it once resolves
/// the issue completely, rather than leaving a residual problem that would
/// generate a "fix" again forever.
///
/// [generateFixes] is called against [projectPath], producing the fixes for
/// whatever issue(s) it targets. Those fixes are applied for real (this
/// mutates files under [projectPath] -- run it against a disposable copy of
/// a project, not something you care about), then [generateFixes] is called
/// again against the now-fixed project. A correct fix means the second call
/// finds nothing left to do.
///
/// Throws [IdempotencyCheckException] if any first-pass fix fails to apply,
/// since the second pass wouldn't be a meaningful comparison at that point.
Future<IdempotencyCheckResult> checkIdempotency({
  required String projectPath,
  required Future<List<Fix>> Function(String projectPath) generateFixes,
}) async {
  final firstPassFixes = await generateFixes(projectPath);
  if (firstPassFixes.isEmpty) {
    return const IdempotencyCheckResult(
      firstPassFixCount: 0,
      secondPassFixCount: 0,
    );
  }

  final result = await applyFixes(
    firstPassFixes,
    projectPath: projectPath,
    apply: true,
  );
  if (result.failed.isNotEmpty) {
    throw IdempotencyCheckException(result.failed);
  }

  final secondPassFixes = await generateFixes(projectPath);

  return IdempotencyCheckResult(
    firstPassFixCount: firstPassFixes.length,
    secondPassFixCount: secondPassFixes.length,
  );
}
