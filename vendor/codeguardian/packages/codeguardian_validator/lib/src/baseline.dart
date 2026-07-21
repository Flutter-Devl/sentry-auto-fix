import 'dart:convert';
import 'dart:io';

import 'package:codeguardian_core/codeguardian_core.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Thrown when `codeguardian-baseline.json` exists but isn't valid JSON or
/// doesn't match the expected shape.
///
/// A distinct type (like [ConfigParseException] from `config_parser.dart`)
/// so callers can tell "the baseline file is broken" (a tool error) apart
/// from "there are findings not in the baseline" (a normal outcome).
class BaselineParseException implements Exception {
  /// Creates the exception with a human-readable [message].
  const BaselineParseException(this.message);

  /// Explanation of what's wrong with the baseline file.
  final String message;

  @override
  String toString() => 'BaselineParseException: $message';
}

/// One pre-existing finding recorded in a baseline file.
@immutable
class BaselineEntry {
  /// Creates a baseline entry. [ruleId], [file], and [note] are optional
  /// human-readable context; only [hash] is used for matching.
  const BaselineEntry({required this.hash, this.ruleId, this.file, this.note});

  /// The finding's content hash (see [computeContentHash]).
  final String hash;

  /// The rule that produced the finding, if recorded.
  final String? ruleId;

  /// The finding's file (relative to the project root), if recorded.
  final String? file;

  /// A free-text note (e.g. why it's baselined), if recorded.
  final String? note;

  /// A JSON-serializable representation of this entry.
  Map<String, dynamic> toJson() => {
        'hash': hash,
        if (ruleId != null) 'ruleId': ruleId,
        if (file != null) 'file': file,
        if (note != null) 'note': note,
      };
}

/// A parsed `codeguardian-baseline.json`: a set of pre-existing findings
/// (identified by content hash) to suppress from future runs.
@immutable
class Baseline {
  /// Creates a baseline from [entries].
  const Baseline({this.entries = const []});

  /// An empty baseline: nothing is suppressed.
  static const empty = Baseline();

  /// Every baselined entry.
  final List<BaselineEntry> entries;

  /// The set of baselined content hashes, for fast lookup.
  Set<String> get hashes => entries.map((e) => e.hash).toSet();

  /// A JSON-serializable representation of this baseline.
  Map<String, dynamic> toJson() => {
        'version': 1,
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// Builds a baseline that suppresses exactly [findings], as of a project
  /// rooted at [projectPath]. Useful for adopting CodeGuardian on an
  /// existing project: baseline everything found today, then only new
  /// findings fail gates going forward.
  factory Baseline.fromFindings(
    List<Finding> findings, {
    required String projectPath,
  }) {
    return Baseline(
      entries: [
        for (final finding in findings)
          BaselineEntry(
            hash: computeContentHash(finding, projectPath: projectPath),
            ruleId: finding.ruleId,
            file: p.relative(finding.file, from: projectPath),
          ),
      ],
    );
  }
}

/// Computes a stable content hash for [finding], for baseline matching.
///
/// Deliberately excludes [Finding.line]/[Finding.column]: unrelated edits
/// earlier in a file shift line numbers without changing the finding
/// itself, and a baseline that broke on every such edit would be useless.
/// Instead this hashes the rule id, the file path *relative to
/// [projectPath]* (so baselines are portable across machines/checkouts),
/// and the offending snippet. If the snippet itself changes, the hash
/// changes too -- that's intentional: it means the code actually changed,
/// so whether it's still the same issue is worth a fresh look.
String computeContentHash(Finding finding, {required String projectPath}) {
  final relativePath = p.relative(finding.file, from: projectPath);
  final material = '${finding.ruleId}|$relativePath|${finding.snippet.trim()}';
  return sha256.convert(utf8.encode(material)).toString();
}

/// Parses `codeguardian-baseline.json` content into a [Baseline].
///
/// Expected shape:
/// ```json
/// {
///   "version": 1,
///   "entries": [
///     { "hash": "...", "ruleId": "long-method", "file": "lib/foo.dart" }
///   ]
/// }
/// ```
/// `entries` may also be a flat list of hash strings for brevity. Throws
/// [BaselineParseException] for invalid JSON or an unexpected shape.
Baseline parseBaseline(String content) {
  final Object? document;
  try {
    document = jsonDecode(content);
  } on FormatException catch (error) {
    throw BaselineParseException(
      'codeguardian-baseline.json is not valid JSON: $error',
    );
  }

  if (document is! Map<String, dynamic>) {
    throw BaselineParseException(
      'codeguardian-baseline.json must be an object at the top level, got '
      '${document.runtimeType}',
    );
  }

  final rawEntries = document['entries'];
  if (rawEntries == null) return const Baseline();
  if (rawEntries is! List) {
    throw BaselineParseException(
      "'entries' must be a list, got ${rawEntries.runtimeType}",
    );
  }

  final entries = rawEntries.map((entry) {
    if (entry is String) return BaselineEntry(hash: entry);
    if (entry is Map<String, dynamic>) {
      final hash = entry['hash'];
      if (hash is! String) {
        throw const BaselineParseException(
          "every baseline entry must have a string 'hash'",
        );
      }
      return BaselineEntry(
        hash: hash,
        ruleId: entry['ruleId'] as String?,
        file: entry['file'] as String?,
        note: entry['note'] as String?,
      );
    }
    throw BaselineParseException(
      'baseline entries must be a hash string or an object, got '
      '${entry.runtimeType}',
    );
  }).toList();

  return Baseline(entries: entries);
}

/// Reads and parses the baseline file at [path].
///
/// Returns [Baseline.empty] if the file doesn't exist -- a project with no
/// baseline is valid and simply suppresses nothing. Throws
/// [BaselineParseException] if it exists but can't be parsed.
Future<Baseline> loadBaseline(String path) async {
  final file = File(path);
  if (!file.existsSync()) return Baseline.empty;
  final content = await file.readAsString();
  return parseBaseline(content);
}

/// Splits [findings] into those not covered by [baseline] and those
/// suppressed by it, as of a project rooted at [projectPath].
({List<Finding> remaining, List<Finding> suppressed}) applyBaseline(
  List<Finding> findings,
  Baseline baseline, {
  required String projectPath,
}) {
  if (baseline.entries.isEmpty) {
    return (remaining: findings, suppressed: const []);
  }

  final hashes = baseline.hashes;
  final remaining = <Finding>[];
  final suppressed = <Finding>[];
  for (final finding in findings) {
    final hash = computeContentHash(finding, projectPath: projectPath);
    if (hashes.contains(hash)) {
      suppressed.add(finding);
    } else {
      remaining.add(finding);
    }
  }
  return (remaining: remaining, suppressed: suppressed);
}
