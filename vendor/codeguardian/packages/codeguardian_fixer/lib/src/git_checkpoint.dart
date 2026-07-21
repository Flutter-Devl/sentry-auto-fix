import 'dart:io';

import 'package:meta/meta.dart';

/// How a [GitCheckpoint] preserved the pre-fix state.
enum CheckpointStrategy {
  /// The working tree had uncommitted changes (tracked or untracked), so
  /// they were captured in a stash entry. Restore with
  /// `git stash apply <ref>`.
  stash,

  /// The working tree was already clean, so a branch was created at the
  /// current `HEAD` instead. Restore with `git reset --hard <ref>` (from
  /// the branch that was being fixed).
  branch,
}

/// A recorded safety net created before a batch of fixes is applied.
@immutable
class GitCheckpoint {
  /// Creates a checkpoint record.
  const GitCheckpoint({
    required this.strategy,
    required this.ref,
    required this.createdAt,
  });

  /// Which mechanism was used to preserve the pre-fix state.
  final CheckpointStrategy strategy;

  /// The stash commit SHA (for [CheckpointStrategy.stash]) or branch name
  /// (for [CheckpointStrategy.branch]) that can be used to recover it.
  final String ref;

  /// When the checkpoint was created.
  final DateTime createdAt;

  @override
  String toString() => 'GitCheckpoint(${strategy.name}, $ref)';
}

/// Thrown when a git checkpoint can't be created.
class GitCheckpointException implements Exception {
  /// Creates the exception with a human-readable [message].
  const GitCheckpointException(this.message);

  /// Explanation of what went wrong.
  final String message;

  @override
  String toString() => 'GitCheckpointException: $message';
}

/// Creates a safety checkpoint of [projectPath]'s current state before a
/// batch of fixes is applied.
///
/// If the working tree has uncommitted changes (tracked or untracked),
/// they're captured in a stash entry (`git stash push --include-untracked`,
/// then immediately `git stash apply`'d back on top so the working tree
/// ends up exactly as it started -- the stash entry is left behind purely
/// as a recovery point). If the working tree is clean, a branch is created
/// at the current commit instead, since there's nothing to stash.
///
/// Throws [GitCheckpointException] if [projectPath] isn't inside a git
/// working tree -- [applyFixes] requires a checkpoint before writing
/// anything, so there is deliberately no "skip checkpointing" path.
Future<GitCheckpoint> createGitCheckpoint(String projectPath) async {
  if (!await _isGitRepository(projectPath)) {
    throw GitCheckpointException(
      '$projectPath is not inside a git working tree; refusing to apply '
      'fixes without git-based checkpointing. Run `git init` (and commit '
      'the current state) first.',
    );
  }

  // Resolve the repo root so that all subsequent git commands use a stable
  // working directory. Running git commands with workingDirectory set to a
  // subdirectory (e.g. lib/utils) is unsafe: `git stash push
  // --include-untracked` removes untracked files from the entire tree, which
  // can delete the subdirectory itself and make the subsequent `git stash
  // apply` fail with ProcessException because workingDirectory no longer
  // exists.
  final repoRoot = await _resolveRepoRoot(projectPath);

  final now = DateTime.now();
  final label = _timestampLabel(now);
  final message = 'codeguardian: pre-fix checkpoint $label';

  if (!await _hasUncommittedChanges(repoRoot)) {
    final branchName = 'codeguardian/checkpoint-$label';
    final branchResult = await Process.run(
      'git',
      ['branch', branchName],
      workingDirectory: repoRoot,
    );
    if (branchResult.exitCode != 0) {
      throw GitCheckpointException('git branch failed: ${branchResult.stderr}');
    }
    return GitCheckpoint(
      strategy: CheckpointStrategy.branch,
      ref: branchName,
      createdAt: now,
    );
  }

  final pushResult = await Process.run(
    'git',
    ['stash', 'push', '--include-untracked', '--message', message],
    workingDirectory: repoRoot,
  );
  if (pushResult.exitCode != 0) {
    throw GitCheckpointException('git stash push failed: ${pushResult.stderr}');
  }

  // After stashing, the working directory is guaranteed to be the repo root
  // (which always exists), so `git stash apply` will not fail because its
  // workingDirectory was removed by the stash.
  final applyResult = await Process.run(
    'git',
    ['stash', 'apply'],
    workingDirectory: repoRoot,
  );
  if (applyResult.exitCode != 0) {
    throw GitCheckpointException(
      'Checkpointed to a stash, but failed to restore the working tree '
      'from it (git stash apply failed): ${applyResult.stderr}',
    );
  }

  final revParseResult = await Process.run(
    'git',
    ['rev-parse', 'stash@{0}'],
    workingDirectory: repoRoot,
  );
  if (revParseResult.exitCode != 0) {
    throw GitCheckpointException(
      'Failed to resolve the checkpoint stash ref: ${revParseResult.stderr}',
    );
  }

  return GitCheckpoint(
    strategy: CheckpointStrategy.stash,
    ref: (revParseResult.stdout as String).trim(),
    createdAt: now,
  );
}

Future<bool> _hasUncommittedChanges(String path) async {
  final result = await Process.run(
    'git',
    ['status', '--porcelain'],
    workingDirectory: path,
  );
  return (result.stdout as String).trim().isNotEmpty;
}

Future<bool> _isGitRepository(String path) async {
  final result = await Process.run(
    'git',
    ['rev-parse', '--is-inside-work-tree'],
    workingDirectory: path,
  );
  return result.exitCode == 0 && (result.stdout as String).trim() == 'true';
}

/// Returns the absolute path of the git repository root that contains [path].
///
/// Using the repo root as [workingDirectory] for stash operations ensures the
/// directory is never deleted by `git stash push --include-untracked` (which
/// can remove subdirectories that consist entirely of untracked files).
Future<String> _resolveRepoRoot(String path) async {
  final result = await Process.run(
    'git',
    ['rev-parse', '--show-toplevel'],
    workingDirectory: path,
  );
  if (result.exitCode != 0) {
    throw GitCheckpointException(
      'Failed to resolve git repository root from $path: ${result.stderr}',
    );
  }
  return (result.stdout as String).trim();
}

String _timestampLabel(DateTime time) {
  final utc = time.toUtc();
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${utc.year}${pad(utc.month)}${pad(utc.day)}-'
      '${pad(utc.hour)}${pad(utc.minute)}${pad(utc.second)}-'
      '${utc.microsecond}';
}
