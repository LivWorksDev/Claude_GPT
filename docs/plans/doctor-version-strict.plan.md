# Plan: doctor-version-strict — parser de versión estricto en el gate crítico

**Backlog:** M18 (P2/S) · **Fecha:** 2026-08-01 · **Modo:** autónomo (Cola 3, tarea 3/3)
**Origen:** hallazgo Major 3 de la primera range review real (`range-review-cola2`),
verificado empíricamente: `Claude Code build 123 version 2.1.110` → `claude_dotted`
imprime `123` → `version_ge` compara 123>2 en el primer campo → PASS falso del gate
crítico ≥ 2.1.111. Hallazgo adicional del borrador, mismo bug de fondo: `2.1.111.7`
(cuatro componentes) también pasa hoy porque `version_ge` solo lee 3 campos.

## Goal

El gate Claude Code ≥ 2.1.111 (M6) existe para ser fail-closed y no lo es: `claude_dotted`
acepta el primer token que empiece por dígito y `version_ge` rellena componentes ausentes
con cero. Objetivo: la versión es SOLO un token puntuado estricto de TRES componentes
decimales (`N.N.N`, sufijo final no numérico tipo `-beta` recortado); números de build,
fechas, dos o cuatro componentes → indeterminable → FAIL, nunca pass ("never assume new").
Mismo criterio en `scripts/codex-doctor.sh` y en el preflight espejado de
`skills/implement/SKILL.md` (gate 3), con pin literal compartido anti-drift.

## Approach

1. **`scripts/codex-doctor.sh` — `claude_dotted`** (comentario ~:78-80, cuerpo ~:81-99):
   se mantiene el bucle de tokens, pero el PRIMER token que empieza por dígito DECIDE:
   recortar sufijo con `${tok%%[!0-9.]*}` (conserva `2.1.111` de `2.1.111-beta`), exigir
   forma `*.*.*`, partir en tres campos con expansión de parámetros
   (`a="${tok%%.*}"; r="${tok#*.}"; b="${r%%.*}"; c="${r#*.}"`); cada campo no vacío y
   solo dígitos (`case … '' | *[!0-9]*) return 1`), imprimir `a.b.c` y return 0; si el
   primer token digit-leading NO es estricto → return 1 INMEDIATO, sin seguir escaneando
   (rescatar una versión posterior permitiría que una fecha puntuada colara un falso
   pass). Un cuarto componente deja `c` con un punto → rechazado. El comentario de
   cabecera pasa a nombrar el criterio con la frase literal que el contract test pinea
   ("strict three-component dotted token") y retira la frase laxa
   "the first dotted-numeric token".
2. **`version_ge`** (~:105-121), defensa en profundidad REAL — validar antes de comparar:
   el retorno temprano actual (un campo mayor/menor decide) dejaría sin validar la basura
   posterior (`3.bad`, `3.0.0.7` ganarían en el primer campo). Estructura nueva: PRIMERO
   parsear y validar AMBOS operandos como exactamente tres campos decimales no vacíos y
   nada después (cualquier violación → return 1, sin comparar nada); SOLO DESPUÉS la
   comparación campo a campo existente. Test directo del comparador (subshell que sourcea
   la función, patrón ya usado por la suite del doctor): `3.bad`/`3.0.0.7` contra
   `2.1.111` → 1 aunque el primer campo sea mayor; los casos válidos intactos.
3. **Mensaje FAIL** (~:219): conservar BYTE A BYTE el prefijo anclado
   "Claude Code version is undeterminable"; solo cambia el paréntesis:
   "printed nothing usable" → "did not print a strict N.N.N dotted version".
4. **`skills/implement/SKILL.md` gate 3** (bullet "Claude Code ≥ 2.1.111", ~:86): insertar
   el criterio estricto CONSERVANDO VERBATIM las dos frases ancladas por
   `skill-critical-contract` ("Read `claude --version` and compare the dotted version
   field by field" y "no `claude` on PATH are all a STOP") — la estrictez es texto
   AÑADIDO, no reescritura de lo anclado; "an output you cannot parse" se sustituye por
   la definición (token N.N.N de tres componentes del primer token digit-leading, sufijo
   recortado; build numbers/fechas/2 o 4 componentes → indeterminable → STOP, never
   assume new).
5. **`tests/doctor-env-matrix.test.sh`** — casos nuevos con el claude_stub en la sección
   de límites del gate (tras ~:147): `Claude Code build 123 version 2.1.110` → rc 1 +
   "FAIL  Claude Code version is undeterminable" + assert_not_contains "ok    Claude Code"
   (el falso pass que este milestone mata); `2026-08-01 2.1.111` (fecha delante) → rc 1
   undeterminable; `2.1.111.7 (Claude Code)` (hoy PASS) → rc 1 undeterminable;
   `2.1 (Claude Code)` → rc 1 undeterminable; `2.1.111-beta (Claude Code)` → rc 0 +
   "ok    Claude Code 2.1.111 >= 2.1.111". Casos existentes (~:110-151) intactos.
6. **`tests/skill-critical-contract.test.sh`** — sección 3 (tras ~:65): el pin anti-drift
   es una FRASE NORMATIVA COMPLETA, no eslóganes — una única oración que contiene TODAS
   las reglas del parse ("the version is ONLY a strict three-component dotted token
   N.N.N taken from the first digit-leading token; a trailing non-numeric suffix is
   trimmed; build numbers, dates, two or four components are undeterminable — never
   assume new, no later token is rescued"), presente VERBATIM en el comentario de
   `claude_dotted` y en el gate 3 de la skill, y asertada ÍNTEGRA en ambos ficheros
   (IMPL_FLAT y el script — patrón del pin `CRITICAL_MIN_CLAUDE`); + ancla NEGATIVA: la
   frase laxa "the first dotted-numeric token" no puede sobrevivir en el doctor.
   Variante rechazada del hallazgo: un checker compartido invocado por skill y doctor —
   el gate 3 es un preflight que EJECUTA el modelo leyendo prosa; un script nuevo
   cambiaría el contrato de ejecución de la skill (fuera del scope de M18). El pin de
   oración completa cierra el drift que el hallazgo señala.
7. **Metadatos (orquestador, fuera de este plan):** plugin.json → 0.24.0, CHANGELOG,
   BACKLOG M18 → hecha, fila de la cola.

## Key decisions & tradeoffs

- **El primer token digit-leading DECIDE — sin rescate posterior:** "build 123 …
  2.1.110" es indeterminable, no se recupera el 2.1.110 de detrás. Tradeoff: una salida
  ambigua que sí contiene versión real bloquea en vez de pasar — es exactamente la
  aceptación de M18; escanear permitiría a un formato ambiguo autocertificarse.
- **`version_ge` endurecido aunque redundante:** ~3 líneas que cierran la trampa para un
  futuro llamante (único consumidor actual verificado por grep: el propio doctor).
- **Sufijo recortado, punto final rechazado:** `2.1.111-beta` ok (lo manda la tarea);
  `2.1.111.` falla (el campo `111.` no es todo-dígitos) — ante ambigüedad, pierde la
  ambigüedad.
- **Pin de frase literal doctor↔skill** (patrón CRITICAL_MIN_CLAUDE): reordenar una de
  las dos copias en el futuro exige tocar la otra a propósito — anti-drift intencional.
- **`2.1` cambia de mensaje** (`<` por zero-fill → undeterminable): veredicto correcto
  por fin por la razón correcta; rc sigue 1; ningún test existente ancla el mensaje viejo
  (verificado por grep).

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/codex-doctor.sh` | claude_dotted estricto, version_ge sin zero-fill + resto vacío, paréntesis del FAIL |
| `skills/implement/SKILL.md` | Gate 3: definición estricta añadida, frases ancladas intactas |
| `tests/doctor-env-matrix.test.sh` | 5 casos nuevos de límites (build/fecha/4-comp/2-comp/-beta) |
| `tests/skill-critical-contract.test.sh` | Anclas del criterio + pin espejo + negativa de la frase laxa |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` | v0.24.0 — orquestador |

## Acceptance & proof

Matriz (todo bajo TANDEM_CRITICAL=1 + implementer opus, claude stub):
- `Claude Code build 123 version 2.1.110` → rc 1, "FAIL  Claude Code version is
  undeterminable", jamás "ok" (hoy: rc 0 con "ok Claude Code 123 >= 2.1.111" —
  reproducido; el caso nuevo no es vacuo).
- `2026-08-01 2.1.111` → rc 1 undeterminable (hoy pasa vía "2026").
- `2.1.111.7` → rc 1 undeterminable (hoy pasa: version_ge ignora el 4º campo).
- `2.1 (Claude Code)` → rc 1 undeterminable.
- `2.1.111-beta (Claude Code)` → rc 0 ok (el recorte de sufijo sobrevive).
- Comparador directo (función sourceada): `version_ge "3.bad" "2.1.111"` → 1 y
  `version_ge "3.0.0.7" "2.1.111"` → 1 (aunque el primer campo gane), validación antes
  de comparación; `version_ge "2.1.111" "2.1.111"` → 0 intacto.
- Sin cambio: `2.1.110` → rc 1 "<"; `2.1.111` y `3.0.0` → rc 0; `2.1.99` → rc 1 "<";
  sin claude en PATH / stub roto / "Claude Code (unknown build)" → rc 1 undeterminable;
  todo silencioso sin CRITICAL y bajo sol.
- `skill-critical-contract` ancla el criterio en SKILL.md Y su espejo literal en el
  doctor, con la frase laxa retirada (negativa).

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- Un cambio real futuro de formato de `claude --version` (prefijo `v`, 4 componentes)
  pasa de falso-pass silencioso a bloqueo ruidoso — es el diseño fail-closed; el FAIL
  nombra la expectativa estricta y las tres salidas (update / TANDEM_IMPLEMENTER=sol /
  quitar TANDEM_CRITICAL) siguen impresas; el formato actual real parsea bien.
- Un byte alterado en las frases ancladas de SKILL.md:86 rompe skill-critical-contract —
  mitigación: añadir texto, no reescribir lo anclado; el test lo detecta.
- shellcheck 0.10.0 limpio sobre las funciones editadas (construcciones ya presentes:
  case, expansión, printf; el propio script declara "no awk, no sed").

## Out of scope

- Cuándo corre el gate (solo CRITICAL=1 + opus; sol y no-CRITICAL siguen silenciosos).
- El valor de `CRITICAL_MIN_CLAUDE` (2.1.111) y su pin existente.
- Los preflights de EFFORT_LEVEL y SUBAGENT_MODEL; `--smoke`; tandem-status/statusline.
- Generalizar el parser a `_common.sh` (un solo consumidor verificado).
- `skills/run/SKILL.md:26` y `skills/implement/SKILL.md:111,145` (mencionan el gate sin
  deletrear el parse); `skills/doctor/SKILL.md` (no menciona la versión).
- M17 (en DEADLOCK resumible) y sus ficheros; metadatos (orquestador).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Rescatar una versión válida detrás de un token ambiguo?** → No: el primer token
   digit-leading decide; lo ambiguo es indeterminable (la aceptación lo exige).
2. **¿Endurecer version_ge además del parser?** → Sí (defensa en profundidad barata).
3. **¿Versión?** → **0.24.0, no la 0.25.0 pre-registrada**: M17 terminó en DEADLOCK sin
   commitear y las versiones siguen el orden de la CADENA, no el de las tareas; si M17 se
   resume y completa, tomará la 0.25.0. Desviación del pre-registro documentada aquí y en
   la cola.
4. **¿Rama?** → `tandem/doctor-version-strict` apilada sobre
   `tandem/status-approval-proof` (88606d3, v0.23.0), con `plan-approve.sh`.
5. **¿Metadatos?** → Orquestador tras la implementación.
