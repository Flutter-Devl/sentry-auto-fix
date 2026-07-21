/// The severity of a [Finding], ordered from least to most serious.
///
/// Declaration order is significant: [index] increases with seriousness, so
/// severities can be compared directly (e.g. `a.index >= Severity.high.index`).
enum Severity {
  /// Informational; no action strictly required.
  info,

  /// Low-impact issue or style concern.
  low,

  /// Should be addressed but is not urgent.
  medium,

  /// Likely exploitable or materially harmful.
  high,

  /// Severe, exploitable issue that should block a release.
  critical;

  /// A short, stable, lower-case identifier suitable for reports and JSON.
  String get label => name;
}
