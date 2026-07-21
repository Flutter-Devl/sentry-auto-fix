import 'package:xml/xml.dart';

/// Returns the 1-based line number of the first line in [lines] containing
/// [needle], or `null` if none does.
///
/// `package:xml`'s DOM tree doesn't track source positions, so findings are
/// located by searching the raw file text for a substring distinctive to the
/// finding (an attribute value, a key name, ...) instead of an exact AST
/// offset. This is a best-effort heuristic: if [needle] happens to also
/// appear earlier in the file for an unrelated reason, the wrong line may be
/// reported.
int? lineContaining(List<String> lines, String needle) {
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].contains(needle)) return i + 1;
  }
  return null;
}

/// The first element of [elements], or `null` if it's empty.
XmlElement? firstElementOrNull(Iterable<XmlElement> elements) {
  for (final element in elements) {
    return element;
  }
  return null;
}
