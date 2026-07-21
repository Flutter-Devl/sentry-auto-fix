/// CodeGuardian AI - Report generation for analysis results.
///
/// Three report formats, all built from the same canonical findings JSON
/// (the shape `Finding.toJson()` produces):
///
///  * [generateHtmlReport] -- a single, self-contained interactive HTML
///    file: a summary score header, and Dart/native findings tables that
///    are independently sortable (by column, with severity sorted by rank)
///    and filterable (by category) via inline vanilla JS -- no server,
///    build step, or framework required.
///  * [generateDashboardHtml] -- a self-contained, dark-themed dashboard
///    (mirroring the Flutter dashboard's look): score header, a filterable
///    findings table, and an AI-suggested-fixes section with confidence and
///    colour-coded diff previews. Drops in next to `report.html`.
///  * [generateMarkdownReport] -- a PR/MR-comment-optimized Markdown report:
///    one summary line plus a collapsible `<details>` section per category.
///  * [generateSarifReport] (and [buildSarifLog]) -- a SARIF 2.1.0 log, the
///    format GitHub code scanning and most CI security dashboards consume.
///
/// Each has a `FromFindings` convenience overload for callers that already
/// have `Finding` objects rather than decoded JSON.
///
/// Other report formats (console, ...) are planned for later phases.
library codeguardian_reporter;

export 'src/dashboard_html.dart';
export 'src/html_report.dart';
export 'src/markdown_report.dart';
export 'src/pipeline_report.dart';
export 'src/refactor_report.dart';
export 'src/sarif_report.dart';
