/// Builds unified diff text (the format `git apply`/`patch` consume) from
/// full old/new file content, so [Fix] producers don't each need to
/// hand-roll diff formatting.
///
/// Uses a classic LCS (longest common subsequence) line diff, which is
/// O(n*m) in time and space. That's fine for the localized, single-file
/// changes rule fixes produce; it is not meant for diffing huge files with
/// changes scattered throughout.
library;

/// Returns unified diff text turning [oldLines] into [newLines], with
/// [relativePath] used in the `---`/`+++` headers (relative to whatever
/// project root the diff will later be applied against, using the standard
/// `a/`/`b/` prefixes).
///
/// [contextLines] is how many unchanged lines to include around each
/// change, standard unified-diff style; `git apply` needs at least a little
/// context to reliably locate a hunk, so don't pass `0` unless you know the
/// surrounding lines can't have shifted.
///
/// Returns an empty string if [oldLines] and [newLines] are identical.
String buildUnifiedDiff(
  String relativePath,
  List<String> oldLines,
  List<String> newLines, {
  int contextLines = 3,
}) {
  final ops = _computeLineDiff(oldLines, newLines);

  final changedIndices = [
    for (var k = 0; k < ops.length; k++)
      if (ops[k].kind != _DiffOpKind.equal) k,
  ];
  if (changedIndices.isEmpty) return '';

  final clusters = _clusterChanges(changedIndices, contextLines);

  final oldLineNumbers = List<int>.filled(ops.length, 0);
  final newLineNumbers = List<int>.filled(ops.length, 0);
  var oldLineNo = 1;
  var newLineNo = 1;
  for (var k = 0; k < ops.length; k++) {
    oldLineNumbers[k] = oldLineNo;
    newLineNumbers[k] = newLineNo;
    if (ops[k].kind != _DiffOpKind.insert) oldLineNo++;
    if (ops[k].kind != _DiffOpKind.delete) newLineNo++;
  }

  final buffer = StringBuffer()
    ..writeln('--- a/$relativePath')
    ..writeln('+++ b/$relativePath');

  for (final cluster in clusters) {
    final hunkStart = (cluster.first - contextLines).clamp(0, ops.length - 1);
    final hunkEnd =
        (cluster.last + contextLines).clamp(0, ops.length - 1);
    final hunkOps = ops.sublist(hunkStart, hunkEnd + 1);

    final oldCount =
        hunkOps.where((op) => op.kind != _DiffOpKind.insert).length;
    final newCount =
        hunkOps.where((op) => op.kind != _DiffOpKind.delete).length;

    buffer.writeln(
      '@@ -${oldLineNumbers[hunkStart]},$oldCount '
      '+${newLineNumbers[hunkStart]},$newCount @@',
    );
    for (final op in hunkOps) {
      switch (op.kind) {
        case _DiffOpKind.equal:
          buffer.writeln(' ${op.line}');
        case _DiffOpKind.delete:
          buffer.writeln('-${op.line}');
        case _DiffOpKind.insert:
          buffer.writeln('+${op.line}');
      }
    }
  }

  return buffer.toString();
}

/// Groups changed-op indices into clusters, merging two changes whose
/// context windows would overlap (gap between them no more than
/// `2 * contextLines`) into a single hunk, matching standard diff behavior.
List<List<int>> _clusterChanges(List<int> changedIndices, int contextLines) {
  final clusters = <List<int>>[];
  var current = [changedIndices.first];

  for (var k = 1; k < changedIndices.length; k++) {
    final gap = changedIndices[k] - current.last - 1;
    if (gap <= contextLines * 2) {
      current.add(changedIndices[k]);
    } else {
      clusters.add(current);
      current = [changedIndices[k]];
    }
  }
  clusters.add(current);
  return clusters;
}

enum _DiffOpKind { equal, insert, delete }

class _DiffOp {
  const _DiffOp(this.kind, this.line);
  final _DiffOpKind kind;
  final String line;
}

/// Computes a line-level edit script turning [oldLines] into [newLines]
/// via a longest-common-subsequence dynamic program, preferring to treat
/// matching lines as unchanged wherever possible.
List<_DiffOp> _computeLineDiff(List<String> oldLines, List<String> newLines) {
  final n = oldLines.length;
  final m = newLines.length;

  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = oldLines[i] == newLines[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }

  final ops = <_DiffOp>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (oldLines[i] == newLines[j]) {
      ops.add(_DiffOp(_DiffOpKind.equal, oldLines[i]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      ops.add(_DiffOp(_DiffOpKind.delete, oldLines[i]));
      i++;
    } else {
      ops.add(_DiffOp(_DiffOpKind.insert, newLines[j]));
      j++;
    }
  }
  while (i < n) {
    ops.add(_DiffOp(_DiffOpKind.delete, oldLines[i]));
    i++;
  }
  while (j < m) {
    ops.add(_DiffOp(_DiffOpKind.insert, newLines[j]));
    j++;
  }
  return ops;
}
