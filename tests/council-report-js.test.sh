#!/usr/bin/env bash
# skills/council/report/informe.tpl.html — the JavaScript of the visual report.
#
# node is a dependency of THIS case only (D9): tests/run.sh links it into the
# sandbox when it exists, and without it this case FAILS naming it — a layer
# that cannot run is a failure, never a silent skip. The plugin never needs it.
#
# A5 no network: none of the forbidden patterns is in the template (D3).
# A8 the two script blocks pass `node --check`, and the pure block — run in
# node:vm, with no document and no window — escapes every HTML of the source,
# keeps links to their three kinds (http(s) in a new tab, an embedded document
# inside, anything else as text), renders the Markdown subset the seats write,
# reads the Spanish dates of the report's tables, and words the provenance of
# the strategy by the status (A3b: «aprobada» only with consensus AND an exact
# copy; a copy that differs is an integrity warning), and shows the effort
# profile (FACTS.run.perfil) and the measured level of each seat with the very
# words and counts of metadatos.md (A7 of the effort profiles).
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

TPL="$REPO_ROOT/skills/council/report/informe.tpl.html"
assert_file "$TPL"

# --- A5 — self-contained, no network -----------------------------------------
for p in '<script src' '<link' '@import' 'url(http' "url('http" 'url("http' 'fetch(' 'XMLHttpRequest' \
  'navigator.sendBeacon' 'new WebSocket' 'EventSource' '<iframe' '<img src="http'; do
  if LC_ALL=C grep -i -F -q -- "$p" "$TPL"; then
    LC_ALL=C grep -i -F -n -- "$p" "$TPL" >&2
    fail "the template holds the forbidden pattern [$p]: the report is self-contained and never touches the network (D3)"
  fi
done
assert_eq 1 "$(LC_ALL=C grep -cxF '<!-- COUNCIL_DATA -->' "$TPL")" "one marker line"
assert_file_contains "$TPL" '<noscript>'
assert_eq 2 "$(LC_ALL=C grep -c '^<script>$' "$TPL")" "two script blocks: the pure one and the build one"
assert_eq 1 "$(LC_ALL=C grep -cF '/* tandem-report:pure:start */' "$TPL")" "one start marker of the pure block"
assert_eq 1 "$(LC_ALL=C grep -cF '/* tandem-report:pure:end */' "$TPL")" "one end marker of the pure block"

# --- A8 — node ---------------------------------------------------------------
command -v node >/dev/null 2>&1 \
  || fail "node not found: this case needs node, a dependency of the tests only (D9) — install it; tests/run.sh links it into the sandbox"

B="$SANDBOX/blocks"
mkdir -p "$B"
LC_ALL=C awk -v d="$B" '/^<script>$/ { n++; f = 1; next } /^<\/script>$/ { f = 0; next } f { print > (d "/block" n ".js") }' "$TPL"
for f in block1 block2; do
  assert_file "$B/$f.js"
  run node --check "$B/$f.js"
  assert_rc 0 "node --check on $f of the template"
done
LC_ALL=C awk '/\/\* tandem-report:pure:start \*\// { f = 1 } f { print } /\/\* tandem-report:pure:end \*\// { exit }' \
  "$TPL" >"$B/pure.js"
cmp -s "$B/pure.js" "$B/block1.js" || fail "the pure block must be the whole first script block"
if LC_ALL=C grep -wqE 'document|window' "$B/pure.js"; then
  LC_ALL=C grep -wnE 'document|window' "$B/pure.js" >&2
  fail "the pure block names document or window"
fi
assert_file_contains "$B/block2.js" "if (typeof document === 'undefined') return;"

cat >"$B/check.js" <<'JS'
'use strict';
const vm = require('vm');
const fs = require('fs');
const assert = require('assert');

// No document, no window: only the language.
const ctx = vm.createContext({});
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), ctx, { filename: 'pure.js' });
const T = ctx.TandemReport;
let failures = 0;
function check(name, fn) {
  try { fn(); } catch (e) { failures++; console.error('FAIL ' + name + ': ' + e.message); }
}
check('the pure block defines TandemReport by itself', () => {
  assert.ok(T, 'TandemReport is not defined');
  for (const k of ['esc', 'inline', 'md', 'tables', 'sections', 'parseFecha', 'niceScale', 'strategyNote', 'tableFits', 'headsFit', 'fitsShape', 'dispMatches',
    'profileText', 'effCount', 'leaderEffortText', 'seatEffortText']) {
    assert.strictEqual(typeof T[k], 'function', k);
  }
  assert.strictEqual(typeof ctx.document, 'undefined');
  assert.strictEqual(typeof ctx.window, 'undefined');
});

const DOCS = { 'brief.md': 'b', 'informe.md': 'i', 'rondas/r1-B.md': 'r', 'estrategia-final.md': 'e' };
const md = (s, base) => T.md(s, base === undefined ? 'informe.md' : base, DOCS);

check('esc', () => {
  assert.strictEqual(T.esc('<a href="x" onclick=\'y\'>&</a>'),
    '&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;&lt;/a&gt;');
});

check('md escapes every HTML of the source text', () => {
  const h = md([
    '</script><script>alert(1)</script>',
    '',
    '<img src=x onerror=alert(1)> <!-- abre -->',
    '',
    '# <b>t</b>',
    '',
    '- <i>x</i>',
    '',
    '| <u>a</u> | b |',
    '| --- | --- |',
    '| <iframe src=x> | 2 |',
    '',
    '> <svg onload=alert(1)>',
    '',
    '[<b>t</b>](https://a.b) `<code>`'
  ].join('\n'));
  for (const bad of ['<script', '</script', '<img', '<!--', '<b>', '<i>', '<u>', '<iframe', '<svg', '<code><code>']) {
    assert.ok(h.indexOf(bad) < 0, 'found ' + bad + ' in: ' + h);
  }
  for (const good of ['&lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt;', '&lt;img src=x onerror=alert(1)&gt;',
    '&lt;!-- abre --&gt;', '<h1>&lt;b&gt;t&lt;/b&gt;</h1>', '<li>&lt;i&gt;x&lt;/i&gt;</li>', '<th>&lt;u&gt;a&lt;/u&gt;</th>',
    '<td>&lt;iframe src=x&gt;</td>', '<blockquote><p>&lt;svg onload=alert(1)&gt;</p></blockquote>',
    '>&lt;b&gt;t&lt;/b&gt;</a>', '<code>&lt;code&gt;</code>']) {
    assert.ok(h.indexOf(good) >= 0, 'missing ' + good + ' in: ' + h);
  }
});

check('a placeholder of the renderer cannot be forged by the text', () => {
  const nul = String.fromCharCode(0);
  const h = md(nul + '0' + nul + ' y `x`');
  assert.ok(h.indexOf(nul) < 0, h);
  assert.strictEqual(h, '<p>0 y <code>x</code></p>');
});

check('links: http(s) in a new tab, an embedded document inside, anything else as text', () => {
  const h = md('[a](javascript:alert(1)) [b](data:text/html;base64,PHNjcmlwdD4=) [c](/abs/ruta) [d](file:///etc/passwd) ' +
    '[e](vbscript:x) [f](mailto:x@y.z) [g](//evil.example/x) [h](#ancla) [i](../no-existe.md) ' +
    '[j](https://a.b) [k](HTTP://c.d/e?f=1&g=2) [l](rondas/r1-B.md) <https://auto.link/x> y https://bare.example/p.');
  const hrefs = [...h.matchAll(/href="([^"]*)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(hrefs, ['https://a.b', 'HTTP://c.d/e?f=1&amp;g=2', '#doc~rondas~r1-B.md',
    'https://auto.link/x', 'https://bare.example/p'], h);
  assert.ok(!/javascript:|data:|vbscript:|file:|mailto:/i.test(hrefs.join(' ')), h);
  const ext = [...h.matchAll(/<a class="ext" [^>]*>/g)].map((m) => m[0]);
  assert.strictEqual(ext.length, 4, h);
  for (const a of ext) {
    assert.ok(a.indexOf('target="_blank"') >= 0 && a.indexOf('rel="noopener noreferrer"') >= 0, a);
  }
  assert.ok(h.indexOf('<a class="int" href="#doc~rondas~r1-B.md">l</a>') >= 0, h);
  assert.ok(h.indexOf('<a class="ext" href="https://a.b" target="_blank" rel="noopener noreferrer">j</a>') >= 0, h);
  // A relative link resolves against the document it is written in.
  assert.ok(T.md('[r](../brief.md)', 'rondas/r1-B.md', DOCS).indexOf('href="#doc~brief.md"') >= 0);
  // The special documents go to their own tab.
  assert.ok(md('[e](estrategia-final.md)').indexOf('href="#estrategia"') >= 0);
});

check('nested lists, also ordered with sub-bullets', () => {
  const h = md('- uno\n  - uno.a\n    - uno.a.i\n- dos\n\n1. primero\n   - sub 1\n   - sub 2\n2. segundo\n\n3. tres\n4. cuatro');
  assert.ok(h.indexOf('<ul><li>uno\n<ul><li>uno.a\n<ul><li>uno.a.i</li></ul></li></ul></li><li>dos</li></ul>') >= 0, h);
  assert.ok(h.indexOf('<ol><li>primero\n<ul><li>sub 1</li><li>sub 2</li></ul></li><li>segundo</li><li>tres</li><li>cuatro</li></ol>') >= 0, h);
  assert.ok(md('3. tres\n4. cuatro').indexOf('<ol start="3"><li>tres</li><li>cuatro</li></ol>') >= 0);
});

check('tables', () => {
  const h = md('| Hito | Fecha |\n| --- | :---: |\n| Piloto | 9 nov |\n| a \\| b | **c** |');
  assert.strictEqual(h, '<div class="tbl"><table><thead><tr><th>Hito</th><th>Fecha</th></tr></thead><tbody>' +
    '<tr><td>Piloto</td><td>9 nov</td></tr><tr><td>a | b</td><td><strong>c</strong></td></tr></tbody></table></div>');
  const t = T.tables('texto\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```\n| x | y |\n| --- | --- |\n```');
  assert.strictEqual(t.length, 1);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(t[0])), { head: ['A', 'B'], rows: [['1', '2']] });
});

check('fenced and indented code', () => {
  assert.strictEqual(md("```js\nvar a = '<b>';\n  sangrado\n```"), '<pre><code>var a = &#39;&lt;b&gt;&#39;;\n  sangrado</code></pre>');
  assert.strictEqual(md('texto\n\n    linea 1\n    linea <2>'), '<p>texto</p>\n<pre><code>linea 1\nlinea &lt;2&gt;</code></pre>');
});

check('quotes, bold, italic, inline code', () => {
  assert.strictEqual(md('> cita\n> segunda'), '<blockquote><p>cita segunda</p></blockquote>');
  assert.strictEqual(md('**negrita** y *cursiva* y `a<b`'), '<p><strong>negrita</strong> y <em>cursiva</em> y <code>a&lt;b</code></p>');
});

check('sections of the report', () => {
  const s = T.sections('# T\n\nintro\n\n## Uno\n\na\n\n```\n## no es sección\n```\n\n## Dos\n\nb', 2);
  assert.strictEqual(s.list.length, 2);
  assert.deepStrictEqual([s.list[0].title, s.list[1].title], ['Uno', 'Dos']);
  assert.ok(s.intro.indexOf('intro') >= 0);
});

check('Spanish dates, with the year of the run and the jump to January', () => {
  const BASE = Date.parse('2026-10-18T09:00:00Z');
  const iso = (t) => new Date(t).toISOString().slice(0, 10);
  const d = (s) => { const r = T.parseFecha(s, BASE); return r && { start: iso(r.start), end: iso(r.end), n: r.ranges.length }; };
  assert.deepStrictEqual(d('19–20 oct'), { start: '2026-10-19', end: '2026-10-20', n: 1 });
  assert.deepStrictEqual(d('26 oct–6 nov'), { start: '2026-10-26', end: '2026-11-06', n: 1 });
  assert.deepStrictEqual(d('16 y 18 nov'), { start: '2026-11-16', end: '2026-11-18', n: 2 });
  assert.deepStrictEqual(d('23 oct'), { start: '2026-10-23', end: '2026-10-23', n: 1 });
  assert.deepStrictEqual(d('16 ene 2027'), { start: '2027-01-16', end: '2027-01-16', n: 1 });
  assert.deepStrictEqual(d('9 ene'), { start: '2027-01-09', end: '2027-01-09', n: 1 });
  assert.deepStrictEqual(d('**23 de octubre**'), { start: '2026-10-23', end: '2026-10-23', n: 1 });
  for (const bad of ['la semana que viene', '31 feb', '', 'oct', '20–19 oct']) {
    assert.strictEqual(T.parseFecha(bad, BASE), null, bad);
  }
});

check('the provenance of the strategy follows the status', () => {
  for (const consensus of [true, false]) {
    for (const identical of [true, false]) {
      const t = T.strategyNote({ last_round: 3, synthesis: 'sintesis-v3.md', identical, consensus });
      if (/aprobad/i.test(t)) assert.ok(consensus && identical, 'claims approval: ' + t);
      if (consensus && identical) assert.match(t, /^Copia exacta de la síntesis v3, aprobada por los dos revisores en la ronda 3\.$/);
      if (!consensus && identical) assert.match(t, /^Copia exacta de la síntesis v3, revisada en la ronda 3, sin consenso\.$/);
      if (!identical) assert.match(t, /^Aviso de integridad: estrategia-final\.md no coincide con la síntesis v3 de la última ronda\.$/);
    }
  }
  assert.match(T.strategyNote({ last_round: 0, identical: false, consensus: false }), /^Aviso de integridad/);
  assert.ok(!/aprobad/i.test(T.strategyNote({})));
});

// Code review of M40, round 1: a table becomes a visual component only with EXACTLY the shape
// that component can show; anything else stays a table, so no content of informe.md is lost.
check('a table becomes a component only with exactly its shape', () => {
  const BASE = Date.parse('2026-10-18T09:00:00Z');
  const t = (src) => T.tables(src)[0];
  assert.ok(T.tableFits(t('| Riesgo | Mitigación |\n|---|---|\n| a | b |\n| c | d |'), 2));
  assert.ok(!T.tableFits(t('| Riesgo | Impacto | Mitigación |\n|---|---|---|\n| a | x | b |'), 2), 'an extra column');
  assert.ok(!T.tableFits(t('| Mitigación | Riesgo | Dueño |\n|---|---|---|\n| b | a | T |'), 2), 'reordered and extra columns');
  assert.ok(!T.tableFits(t('| Riesgo | Mitigación |\n|---|---|\n| a | b | c |'), 2), 'a row with an extra cell');
  assert.ok(!T.tableFits(t('| Riesgo | Mitigación |\n|---|---|\n| a |'), 2), 'a row with a missing cell');
  const met = '| Hito | Fecha | Condición |\n|---|---|---|\n| Hito | 15 nov | DAU7 ≥ 100 |\n';
  assert.ok(T.tableFits(t(met), 3, 1, BASE));
  assert.ok(!T.tableFits(t(met + '| Otro | cuando se pueda | algo |\n'), 3, 1, BASE), 'an unreadable date');
  assert.ok(!T.tableFits(t('| Hito | Fecha | Condición | Abandono |\n|---|---|---|---|\n| H | 15 nov | DAU7 ≥ 100 | x |'), 3, 1, BASE), 'a fourth column');
  assert.ok(T.tableFits(t('| Fecha | Qué |\n|---|---|\n| 19–20 oct | algo |'), 2, 0, BASE));
  assert.ok(!T.tableFits(t('| Fecha | Qué | Quién |\n|---|---|---|\n| 19–20 oct | algo | T |'), 2, 0, BASE), 'a third column in the calendar');
  assert.ok(!T.tableFits(t('| Fecha | Qué |\n|---|---|\n| la semana que viene | algo |'), 2, 0, BASE), 'an unreadable calendar date');
  assert.ok(!T.tableFits(undefined, 2));
});

// Round 2: the SAME columns in another order do not fit either — positional conversion would
// swap their roles (a mitigation shown as the risk). Each component names the headers it can
// show, by meaning and in order.
check('a table becomes a component only with its headers, in their order', () => {
  const BASE = Date.parse('2026-10-18T09:00:00Z');
  const t = (src) => T.tables(src)[0];
  // the real canary's headers
  assert.ok(T.fitsShape(t('| Fecha | Qué |\n|---|---|\n| 19–20 oct | algo |'), 'calendario', BASE));
  assert.ok(T.fitsShape(t('| Hito o puerta | Fecha | Condición |\n|---|---|---|\n| Hito | 15 nov | DAU7 ≥ 100 |'), 'metricas', BASE));
  assert.ok(T.fitsShape(t('| Riesgo | Mitigación |\n|---|---|\n| Caída del proveedor | Activar proveedor alternativo |'), 'riesgos'));
  assert.ok(T.headsFit('supuestos', ['Supuesto', 'Experimento mínimo']));
  // case, accents and emphasis do not matter
  assert.ok(T.fitsShape(t('| **RIESGO** | Mitigacion propuesta |\n|---|---|\n| a | b |'), 'riesgos'));
  // reorder only: same width, roles swapped
  assert.ok(!T.fitsShape(t('| Mitigación | Riesgo |\n|---|---|\n| Activar proveedor alternativo | Caída del proveedor |'), 'riesgos'), 'reordered risks');
  assert.ok(!T.fitsShape(t('| Qué | Fecha |\n|---|---|\n| algo | 19–20 oct |'), 'calendario', BASE), 'reordered calendar');
  assert.ok(!T.fitsShape(t('| Condición | Fecha | Hito |\n|---|---|---|\n| DAU7 ≥ 100 | 15 nov | Hito |'), 'metricas', BASE), 'reordered metrics');
  assert.ok(!T.headsFit('supuestos', ['Experimento mínimo', 'Supuesto']), 'reordered assumptions');
  // other headers of the same width
  assert.ok(!T.fitsShape(t('| Riesgo | Dueño |\n|---|---|\n| a | T |'), 'riesgos'), 'an unknown second header');
  assert.ok(!T.fitsShape(t('| Riesgo | Mitigación |\n|---|---|\n| a | b |'), 'otra'), 'an unknown kind');
  assert.ok(!T.fitsShape(undefined, 'riesgos'));
});

check('the disposition filter: OTRA selects what is outside the known set', () => {
  const K = ['ACEPTADA', 'RECHAZADA', 'ABIERTA'];
  assert.ok(T.dispMatches([], 'ACEPTADA', K));
  assert.ok(T.dispMatches(['OTRA'], '', K));
  assert.ok(T.dispMatches(['OTRA'], 'PENDIENTE', K));
  assert.ok(!T.dispMatches(['OTRA'], 'ACEPTADA', K), 'a known disposition is not OTRA');
  assert.ok(T.dispMatches(['ACEPTADA'], 'ACEPTADA', K));
  assert.ok(!T.dispMatches(['ACEPTADA'], '', K));
});

check('the effort profile and the measured levels, in the words of metadatos.md', () => {
  assert.strictEqual(T.profileText({ nombre: 'estandar', nombre_visible: 'estándar', esfuerzo: 'xhigh', implicito: false }), 'Perfil estándar · xhigh');
  assert.strictEqual(T.profileText({ nombre: 'critico', nombre_visible: 'crítico', esfuerzo: 'max', implicito: true }), 'Perfil crítico · max (implícito)');
  assert.strictEqual(T.profileText(null), 'Perfil sin elegir');
  assert.strictEqual(T.effCount({ xhigh: 1, high: 2, max: 1 }), 'high ×2, max ×1, xhigh ×1');
  const m = { medido: true, intake: { total: 2, por_esfuerzo: { max: 2 } }, debate: { total: 3, por_esfuerzo: { xhigh: 1, high: 2 } } };
  assert.strictEqual(T.leaderEffortText(m), 'medido (deduplicado por message.id) — debate: high ×2, xhigh ×1 · intake: max ×2');
  assert.strictEqual(T.leaderEffortText({ medido: true, intake: { total: 0 }, debate: { total: 0 } }),
    'medido (deduplicado por message.id) — debate: sin mensajes · intake: sin mensajes');
  assert.strictEqual(T.leaderEffortText({ medido: false }), 'no medido');
  assert.strictEqual(T.leaderEffortText(undefined), 'no medido');
  assert.strictEqual(T.seatEffortText({ esfuerzos: ['xhigh'] }), 'xhigh');
  assert.strictEqual(T.seatEffortText({ esfuerzos: [] }), 'no verificado');
  assert.strictEqual(T.esc(T.profileText({ nombre: '<b>', esfuerzo: 'x' })), 'Perfil &lt;b&gt; · x');
});

if (failures) { console.error(failures + ' check(s) failed'); process.exit(1); }
console.log('pure block: all checks passed');
JS
run node "$B/check.js" "$B/pure.js"
if [ "$RC" -ne 0 ]; then cat "$ERR" >&2; fi
assert_rc 0 "the pure block of the template, in node:vm"

note "council report JS: no network patterns, node --check on both blocks, pure block (escape, links, Markdown, dates, provenance) in node:vm"
