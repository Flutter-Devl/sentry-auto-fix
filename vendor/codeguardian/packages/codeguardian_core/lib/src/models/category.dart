/// The class of problem a [Finding] represents.
///
/// Categories group rules so findings can be filtered and reported by concern.
enum Category {
  /// A potential security vulnerability (injection, weak crypto, secrets, etc.).
  security,

  /// A privacy or data-handling concern (PII leakage, excessive permissions).
  privacy,

  /// A correctness or reliability bug.
  correctness,

  /// A performance problem or inefficiency.
  performance,

  /// A maintainability, readability, or style concern.
  style,

  /// Anything that does not fit the other categories.
  other;

  /// A short, stable, lower-case identifier suitable for reports and JSON.
  String get label => name;
}
