import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'fix.dart';
import 'git_checkpoint.dart';

/// A [Fix] that failed to apply, with the reason why.
@immutable
class FixFailure {
  /// Creates a failure record.
  const FixFailure({required this.fix, required this.reason});

  /// The fix that could not be applied.
  final Fix fix;

  /// `git apply`'s explanation of why (e.g. the file has changed since the
  /// fix was generated, so the diff's context no longer matches).
  final String reason;

  @override
  String toString() => 'FixFailure(${fix.file}: $reason)';
}

/// The outcome of an [applyFixes] call.
@immutable
class ApplyFixesResult {
  /// Creates a result.
  const ApplyFixesResult({
    required this.dryRun,
    required this.succeeded,
    required this.failed,
    this.checkpoint,
  });

  /// Whether this was a dry run (`apply: false`, the default): [succeeded]
  /// lists the fixes that *would* be applied, but nothing was written.
  final bool dryRun;

  /// Fixes that were applied (or, in a dry run, would be).
  final List<Fix> succeeded;

  /// Fixes that failed to apply. Always empty in a dry run.
  final List<FixFailure> failed;

  /// The safety checkpoint created before applying, or `null` if this was a
  /// dry run (no checkpoint is needed when nothing is written) or there was
  /// nothing to apply.
  final GitCheckpoint? checkpoint;
}

/// Applies [fixes] to files under [projectPath].
///
/// **Dry run by default.** Unless [apply] is explicitly `true`, no file on
/// disk is touched -- this just reports which fixes would be applied. This
/// default is deliberate: a fixer that writes to disk unless told not to is
/// much easier to invoke by accident (a copy-pasted command, a CI job
/// missing a flag) than one that requires explicit opt-in to write.
///
/// When [apply] is `true`:
///  1. A [GitCheckpoint] is created first (see [createGitCheckpoint]) so the
///     pre-fix state is always recoverable. This requires [projectPath] to
///     be inside a git working tree; there is no way to disable this.
///  2. Each fix's unified diff is applied via `git apply`. Fixes are
///     independent: if one fails (for example because the file changed
///     since the underlying finding was generated, so the diff's context no
///     longer matches), the rest still get applied, and the failure is
///     reported in [ApplyFixesResult.failed] rather than aborting the batch.
Future<ApplyFixesResult> applyFixes(
  List<Fix> fixes, {
  required String projectPath,
  bool apply = false,
}) async {
  if (fixes.isEmpty) {
    return ApplyFixesResult(
      dryRun: !apply,
      succeeded: const [],
      failed: const [],
    );
  }

  if (!apply) {
    return ApplyFixesResult(
      dryRun: true,
      succeeded: List.unmodifiable(fixes),
      failed: const [],
    );
  }

  final checkpoint = await createGitCheckpoint(projectPath);

  final succeeded = <Fix>[];
  final failed = <FixFailure>[];
  for (final fix in fixes) {
    final error = await _applyUnifiedDiff(projectPath, fix.diff);
    if (error == null) {
      succeeded.add(fix);
    } else {
      failed.add(FixFailure(fix: fix, reason: error));
    }
  }

  return ApplyFixesResult(
    dryRun: false,
    succeeded: List.unmodifiable(succeeded),
    failed: List.unmodifiable(failed),
    checkpoint: checkpoint,
  );
}

/// Applies a single unified diff via `git apply`, returning `null` on
/// success or `git apply`'s stderr output on failure.
Future<String?> _applyUnifiedDiff(String projectPath, String diffText) async {
  final tempFile = File(
    p.join(
      Directory.systemTemp.path,
      'codeguardian_fix_${DateTime.now().microsecondsSinceEpoch}.patch',
    ),
  );
  await tempFile.writeAsString(diffText);

  try {
    final result = await Process.run(
      'git',
      ['apply', '--whitespace=nowarn', tempFile.path],
      workingDirectory: projectPath,
    );
    if (result.exitCode != 0) {
      return result.stderr.toString().trim();
    }
    return null;
  } finally {
    if (tempFile.existsSync()) await tempFile.delete();
  }
}
