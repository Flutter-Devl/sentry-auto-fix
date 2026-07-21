import 'package:analyzer/dart/analysis/results.dart';

/// Returns the trimmed source text of the 1-based [lineNumber] in [unit].
///
/// Returns an empty string if [lineNumber] is out of range, which should only
/// happen if a rule computes a location incorrectly.
String lineSnippet(ResolvedUnitResult unit, int lineNumber) {
  final lines = unit.content.split('\n');
  final index = lineNumber - 1;
  if (index < 0 || index >= lines.length) return '';
  return lines[index].trim();
}

/// Whether [unit]'s source starts with a standard "generated code, do not
/// edit" header, as emitted by build_runner-based generators
/// (json_serializable, retrofit_generator, freezed, easy_localization,
/// mockito, ...).
///
/// Rules that flag code-quality issues (duplication, hardcoded values, ...)
/// should skip generated files: nobody hand-edits them, so a finding there
/// isn't actionable -- it just gets regenerated on the next build.
bool isGeneratedFile(ResolvedUnitResult unit) {
  final headLength =
      unit.content.length < 500 ? unit.content.length : 500;
  final head = unit.content.substring(0, headLength).toLowerCase();
  return head.contains('generated code') ||
      head.contains('do not edit') ||
      head.contains('do not modify by hand');
}
