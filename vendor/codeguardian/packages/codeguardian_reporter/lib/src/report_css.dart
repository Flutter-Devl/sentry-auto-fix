/// The report's inline stylesheet, embedded directly into the generated
/// HTML so the file stays a single, self-contained artifact.
const String reportCss = '''
:root {
  color-scheme: light dark;
  --bg: #f8fafc;
  --panel-bg: #ffffff;
  --text: #0f172a;
  --muted: #64748b;
  --border: #e2e8f0;
  --accent: #4338ca;
  --row-hover: #f1f5f9;
  --critical: #dc2626;
  --high: #ea580c;
  --medium: #ca8a04;
  --low: #2563eb;
  --info: #64748b;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0b1120;
    --panel-bg: #131c31;
    --text: #e2e8f0;
    --muted: #94a3b8;
    --border: #253150;
    --accent: #818cf8;
    --row-hover: #1b2842;
    --critical: #f87171;
    --high: #fb923c;
    --medium: #facc15;
    --low: #60a5fa;
    --info: #94a3b8;
  }
}

* { box-sizing: border-box; }

body {
  margin: 0;
  padding: 2rem 1.5rem 4rem;
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica,
    Arial, sans-serif;
  line-height: 1.5;
}

main {
  max-width: 1100px;
  margin: 0 auto;
}

header.summary {
  max-width: 1100px;
  margin: 0 auto 2rem;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 1.5rem;
  background: var(--panel-bg);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 1.5rem;
}

.score-circle {
  flex: 0 0 auto;
  width: 88px;
  height: 88px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.75rem;
  font-weight: 700;
  color: #fff;
  background: var(--score-color, var(--accent));
}

.summary-text h1 {
  margin: 0 0 0.35rem;
  font-size: 1.35rem;
}

.summary-meta {
  color: var(--muted);
  font-size: 0.9rem;
  margin: 0 0 0.6rem;
}

.badge-row {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
}

.badge {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.15rem 0.6rem;
  border-radius: 999px;
  font-size: 0.8rem;
  font-weight: 600;
  color: #fff;
}

.badge.severity-critical { background: var(--critical); }
.badge.severity-high { background: var(--high); }
.badge.severity-medium { background: var(--medium); color: #1f1300; }
.badge.severity-low { background: var(--low); }
.badge.severity-info { background: var(--info); }

section.findings {
  background: var(--panel-bg);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 1.25rem 1.5rem 1.5rem;
  margin-bottom: 1.5rem;
}

section.findings h2 {
  margin: 0 0 0.75rem;
  font-size: 1.1rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

section.findings h2 .count {
  color: var(--muted);
  font-weight: 400;
  font-size: 0.9rem;
}

.filters {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  margin-bottom: 1rem;
}

.filter-chip {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.25rem 0.65rem;
  border: 1px solid var(--border);
  border-radius: 999px;
  font-size: 0.85rem;
  cursor: pointer;
  user-select: none;
}

.filter-chip input { cursor: pointer; }

.table-scroll {
  overflow-x: auto;
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.9rem;
}

th, td {
  text-align: left;
  padding: 0.55rem 0.75rem;
  border-bottom: 1px solid var(--border);
  white-space: nowrap;
}

td.message-cell, td.file-cell {
  white-space: normal;
  word-break: break-word;
}

th {
  cursor: pointer;
  color: var(--muted);
  font-weight: 600;
  user-select: none;
  position: relative;
}

th:hover { color: var(--text); }

th[data-sort-direction]::after {
  content: attr(data-sort-direction);
  margin-left: 0.35rem;
}

th[data-sort-direction='asc']::after { content: '\\25B2'; }
th[data-sort-direction='desc']::after { content: '\\25BC'; }

tbody tr:hover { background: var(--row-hover); }

.severity-pill {
  display: inline-block;
  padding: 0.1rem 0.55rem;
  border-radius: 999px;
  font-size: 0.78rem;
  font-weight: 600;
  color: #fff;
}

.severity-pill.severity-critical { background: var(--critical); }
.severity-pill.severity-high { background: var(--high); }
.severity-pill.severity-medium { background: var(--medium); color: #1f1300; }
.severity-pill.severity-low { background: var(--low); }
.severity-pill.severity-info { background: var(--info); }

.empty-state {
  color: var(--muted);
  font-style: italic;
  padding: 0.5rem 0;
}

footer {
  max-width: 1100px;
  margin: 1.5rem auto 0;
  color: var(--muted);
  font-size: 0.8rem;
  text-align: center;
}
''';
