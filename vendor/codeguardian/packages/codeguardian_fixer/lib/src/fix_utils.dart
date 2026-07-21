import 'dart:io';

import 'package:path/path.dart' as p;

import 'fix.dart';
import 'unified_diff.dart';

/// Builds a [Fix] for [file] by transforming its full text content.
///
/// Reads [file], applies [transform] to get the new content, and builds the
/// unified diff between them (with [file]'s path relative to [projectPath]
/// in the diff headers, as `git apply` expects). This is the building block
/// every fix generator in this package uses; most only need the simpler
/// [buildFixFromLineTransform].
Fix buildFixFromContentTransform({
  required String ruleId,
  required String file,
  required String projectPath,
  required String Function(String oldContent) transform,
}) {
  final oldContent = File(file).readAsStringSync();
  final newContent = transform(oldContent);
  final relativePath = p.relative(file, from: projectPath);
  final diff = buildUnifiedDiff(
    relativePath,
    splitContentLines(oldContent),
    splitContentLines(newContent),
  );
  return Fix(ruleId: ruleId, file: file, diff: diff);
}

/// Builds a [Fix] for [file] by transforming its content as a list of lines.
///
/// A thin convenience wrapper around [buildFixFromContentTransform] for the
/// common case of a fix that inserts, removes, or edits whole lines rather
/// than an arbitrary sub-expression.
Fix buildFixFromLineTransform({
  required String ruleId,
  required String file,
  required String projectPath,
  required List<String> Function(List<String> oldLines) transform,
}) {
  return buildFixFromContentTransform(
    ruleId: ruleId,
    file: file,
    projectPath: projectPath,
    transform: (oldContent) =>
        joinContentLines(transform(splitContentLines(oldContent))),
  );
}

/// Splits [content] into lines for diffing/editing, dropping the trailing
/// empty element `String.split('\n')` produces when [content] ends with a
/// newline (which nearly every source file does).
///
/// That trailing empty string isn't a real line -- it's an artifact of
/// `split`. Feeding it to [buildUnifiedDiff] as if it were a line some
/// fixes' hunks end up including as trailing context, which `git apply`
/// then refuses to match against the real end-of-file. Pair this with
/// [joinContentLines] when reconstructing content from an edited line list.
List<String> splitContentLines(String content) {
  final lines = content.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) {
    return lines.sublist(0, lines.length - 1);
  }
  return lines;
}

/// Joins [lines] back into file content, restoring the single trailing
/// newline convention that [splitContentLines] strips.
String joinContentLines(List<String> lines) => '${lines.join('\n')}\n';

/// The whitespace [line] starts with, for reproducing indentation when
/// inserting a new line next to it.
String leadingWhitespaceOf(String line) =>
    RegExp(r'^[ \t]*').firstMatch(line)?.group(0) ?? '';
