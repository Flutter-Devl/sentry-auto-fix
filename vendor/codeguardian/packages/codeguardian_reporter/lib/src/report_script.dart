/// The report's inline behavior: generic column sorting (with a severity
/// rank so "critical" sorts above "info" rather than alphabetically) and
/// per-category filter checkboxes, for each findings section independently.
///
/// This is the static part of the script; `generateHtmlReport` prepends the
/// embedded `DART_FINDINGS`/`NATIVE_FINDINGS` data and appends the two
/// `initSection(...)` calls that kick it off.
///
/// Deliberately written without JS template literals (backtick strings with
/// `${}`), since this is interpolated into a Dart string literal and `${}`
/// would be parsed as Dart interpolation, not JS.
const String reportScript = '''
var SEVERITY_RANK = {critical: 4, high: 3, medium: 2, low: 1, info: 0};
var COLUMNS = ['severity', 'category', 'ruleId', 'file', 'line', 'message'];

function cellText(value) {
  return value === null || value === undefined ? '' : String(value);
}

function compareRows(a, b, key, direction) {
  var va = a[key];
  var vb = b[key];
  if (key === 'severity') {
    va = SEVERITY_RANK.hasOwnProperty(va) ? SEVERITY_RANK[va] : -1;
    vb = SEVERITY_RANK.hasOwnProperty(vb) ? SEVERITY_RANK[vb] : -1;
  } else if (key === 'line' || key === 'column') {
    va = Number(va) || 0;
    vb = Number(vb) || 0;
  } else {
    va = cellText(va).toLowerCase();
    vb = cellText(vb).toLowerCase();
  }
  if (va < vb) return direction === 'asc' ? -1 : 1;
  if (va > vb) return direction === 'asc' ? 1 : -1;
  return 0;
}

function initSection(sectionId, findings) {
  var section = document.getElementById(sectionId);
  if (!section) return;

  var countEl = section.querySelector('.count');
  var table = section.querySelector('table');
  var tbody = section.querySelector('tbody');
  var emptyState = section.querySelector('.empty-state');
  var filtersEl = section.querySelector('.filters');

  if (countEl) countEl.textContent = String(findings.length);

  if (findings.length === 0) {
    if (table) table.hidden = true;
    if (filtersEl) filtersEl.hidden = true;
    if (emptyState) emptyState.hidden = false;
    return;
  }

  var categories = [];
  findings.forEach(function (finding) {
    if (categories.indexOf(finding.category) === -1) {
      categories.push(finding.category);
    }
  });
  categories.sort();

  var activeCategories = {};
  categories.forEach(function (category) { activeCategories[category] = true; });

  var sortKey = 'severity';
  var sortDirection = 'desc';

  function renderRows() {
    var visible = findings.filter(function (finding) {
      return activeCategories[finding.category];
    });
    visible.sort(function (a, b) {
      return compareRows(a, b, sortKey, sortDirection);
    });

    tbody.textContent = '';
    visible.forEach(function (finding) {
      var tr = document.createElement('tr');
      COLUMNS.forEach(function (key) {
        var td = document.createElement('td');
        if (key === 'severity') {
          var pill = document.createElement('span');
          pill.className = 'severity-pill severity-' + cellText(finding.severity);
          pill.textContent = cellText(finding.severity);
          td.appendChild(pill);
        } else {
          td.textContent = cellText(finding[key]);
          if (key === 'message' || key === 'file') {
            td.className = key + '-cell';
          }
        }
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
  }

  if (filtersEl) {
    categories.forEach(function (category) {
      var label = document.createElement('label');
      label.className = 'filter-chip';
      var checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = true;
      checkbox.addEventListener('change', function () {
        activeCategories[category] = checkbox.checked;
        renderRows();
      });
      label.appendChild(checkbox);
      label.appendChild(document.createTextNode(' ' + category));
      filtersEl.appendChild(label);
    });
  }

  var headers = section.querySelectorAll('th[data-key]');
  headers.forEach(function (th) {
    th.addEventListener('click', function () {
      var key = th.getAttribute('data-key');
      if (sortKey === key) {
        sortDirection = sortDirection === 'asc' ? 'desc' : 'asc';
      } else {
        sortKey = key;
        sortDirection = key === 'severity' ? 'desc' : 'asc';
      }
      headers.forEach(function (h) { h.removeAttribute('data-sort-direction'); });
      th.setAttribute('data-sort-direction', sortDirection);
      renderRows();
    });
  });

  var defaultHeader = section.querySelector('th[data-key="severity"]');
  if (defaultHeader) defaultHeader.setAttribute('data-sort-direction', 'desc');

  renderRows();
}
''';
