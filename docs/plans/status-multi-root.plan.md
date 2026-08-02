# Plan: status-multi-root — reconciliación multi-raíz o contradicción explícita

**Backlog:** M17 (P2/M) · **Fecha:** 2026-08-01 · **Modo:** autónomo (Cola 3, tarea 2/3)
**Origen:** hallazgo Major 2 de la primera range review real (`range-review-cola2`).

## Goal

`resolve_state_root` se queda con la PRIMERA raíz candidata que contenga cualquier
evidencia del slug (CLAUDE_PROJECT_DIR → PWD → checkout principal) y todo el análisis lee
solo de ella: un log rancio o estado parcial en un worktree enlazado enmascara el run
completo y autoritativo del principal — fase y `next:` incorrectos. Objetivo: inspeccionar
TODAS las raíces candidatas (dedupe por ruta FÍSICA), reconciliar evidencia consistente de
forma determinista (gana la fase más avanzada; la raíz elegida siempre visible en el
report) y declarar contradicción explícita — ambas raíces, ambas fases, exit 2, sin paso
siguiente — cuando los HECHOS DE IDENTIDAD del run divergen. Contratos duros intactos:
read-only estricto, sin heredoc/here-string/mktemp, exit 0/2/64, stderr solo en 2/64,
bash 3.2/BSD.

## Approach

Todo sobre `scripts/tandem-status.sh` (+ tests + skill):

1. **Dedupe físico:** en `add_cand` (~:103), `pwd` → `pwd -P`. Dos rutas lógicas al mismo
   directorio (symlink al checkout) dejan de contar como dos raíces. En macOS los
   sandboxes cuelgan de `/var` symlinkeado: las aserciones de ruta en tests van en físico.
2. **`FASE_RANK` sin segunda fuente de verdad:** asignado en cada rama del MISMO if/elif
   que ya fija `FASE` — que tras M16 tiene DOCE peldaños (final, contradictorio—rama
   avanzó, final no verificado, contradictorio—commits sin registro, code review, gate,
   implementación, plan aprobado, aprobación no verificada, plan en revisión, borrador,
   desconocido): rangos ÚNICOS 11..0, sin compartir valor. Nada de un mapa
   string→número paralelo que pueda derivar. Test de cada par adyacente de fases, el
   peldaño nuevo de M16 incluido.
3. **`analyze` parametrizado por raíz:** `analyze <slug> <root>` — la llamada a
   `resolve_state_root` (~:366) se sustituye por `ST_BASE="$2"`. El resto no cambia:
   `GIT_ROOT` ya deriva de ST_BASE y la búsqueda de la copia de trabajo del plan ya
   recorre todas las candidatas. **Extensión necesaria (`OP_ID_VALID`):** el parsing Opus
   actual solo lee status/sentinel/rondas — analyze gana la exportación VALIDADA del
   linaje: `branch` exactamente `tandem/<slug>`, `agent_type` del enum cerrado del
   contrato de implement (normalización legacy incluida), `plan_hash` no vacío con forma
   de blob id (y verificación git del blob cuando hay git). Linaje inválido →
   `OP_ID_VALID=0`, no-comparable, degrada como corrupto — jamás entra en la sonda de
   identidad. **Y domina la selección a fase igual:** a MISMA fase, una raíz con linaje
   Opus VÁLIDO domina a una con linaje inválido ANTES de cualquier comparación de
   progreso (la regla válido>inválido del progreso exige identidad igual, que no puede
   establecerse con un linaje corrupto — sin esta regla, la raíz prioritaria corrupta
   empataría en fase y ganaría por prioridad, enmascarando un IMPLEMENTATION_COMPLETE
   válido); prioridad solo cuando AMBOS linajes son inválidos.
4. **Resolutor multi-raíz** (reemplaza `resolve_state_root`, ~:169-185):
   - `resolve_slug` llama a `compute_keys "$slug"` como PRIMERA instrucción — antes de
     cualquier descubrimiento de evidencia o sonda: `slug_has_evidence` usa K_PLAN/K_CR
     precomputadas, y en modo lista un slug posterior evaluado con las claves del
     anterior perdería raíces solo-thread. Tests: dual-root con evidencia SOLO de thread,
     y modo lista multi-slug que expondría claves rancias.
   - `evidence_roots <slug>`: recorre CAND[] con el `slug_has_evidence` existente →
     EVR[]/EVR_N (orden de prioridad de candidatas intacto).
   - `resolve_slug <slug>`: EVR_N=0 → descubrir y GUARDAR los dueños de la evidencia
     no-estado: recorrer las candidatas en orden de prioridad registrando quién posee la
     copia de trabajo del plan y en qué repo existe la rama; la raíz analizada/nombrada es
     la PRIMERA candidata que posee el plan; sin plan pero con rama, la PRIMERA raíz git
     registrada como dueña de la rama (el descubrimiento de lista ya recorre los repos de
     todas las candidatas — analizar la rama contra el repo del `DEFAULT_ROOT`, donde
     puede no existir, produciría "sin evidencia" o nombraría a un no-dueño); sin nada,
     `DEFAULT_ROOT` canonicalizado. Si plan
     y rama viven en candidatas DISTINTAS, la fila lo muestra
     (`raíz: <dueña del plan> (sin estado .tandem) · rama en <otra>`) — visible, jamás un
     dueño inventado. EVR_N=1 → esa raíz; EVR_N≥2 →
     (a) `analyze` por raíz PRIMERO, guardando R_FASE[i]/R_RANK[i] y exportando los
     HECHOS DE IDENTIDAD **ya validados por el propio analyze** — jamás valores crudos:
     `PLAN_COMMIT` solo si el registro salió VÁLIDO (un registro corrupto o no verificado
     queda NO-comparable y conserva su degradación existente — nunca dispara split-brain),
     el sha terminal solo si git lo verificó, los thread ids de review/$K_PLAN,
     implement/$K_PLAN y review/$K_CR (una línea, lector `tr -d '[:space:]'`), y del
     intento Opus SOLO el linaje INMUTABLE documentado — `plan_hash` + `branch` (la
     identidad del intento según el contrato de implement) más `agent_type`; JAMÁS
     `agent.id` (una recovery legítima lanza agente fresco y guarda la identidad nueva
     sin resetear el intento — compararlo daría split-brain falso entre un snapshot
     pre-recovery y otro post-recovery) ni task_id/status/sentinel;
     (b) un hecho de identidad presente en DOS raíces con valores VALIDADOS distintos →
     CONTRA=1 recordando el hecho;
     (c) sin contradicción: gana el rango máximo; EMPATE de rango → ORDEN DE REVISIÓN
     explícito antes que prioridad, con la MISMA identidad:
     · Thread: mayor turno gana; a MISMO turno, respuesta completada > respuesta ausente;
       mismo turno con DOS verdicts completados DISTINTOS → contradicción (no hay orden).
     · Opus: el comparador solo opera sobre una TUPLA DE PROGRESO VALIDADA —
       `continuation_rounds` entero no negativo, `status` exactamente running|terminal,
       sentinel dentro de los valores documentados o null; progreso inválido queda
       NO-comparable y degrada como estado corrupto (jamás entra en aritmética ni
       dispara split-brain). Con tupla válida: mayor `continuation_rounds` gana PRIMERO
       (una running de ronda 1 es más nueva que una terminal de ronda 0); a MISMA ronda,
       terminal > running; revisiones terminales iguales con sentinels/resultados
       distintos → contradicción. DOMINANCIA válido>inválido: con fase e identidad
       inmutable iguales, la tupla VÁLIDA domina a la inválida (el snapshot corrupto
       jamás gana por prioridad ni fuerza contradicción); prioridad solo cuando AMBAS
       son inválidas; "incomparable → contradicción" queda reservado a DOS tuplas
       válidas.
     Dos copias del mismo run donde la rancia es la prioritaria ya no emiten el next
     equivocado; TODO igual (copias idénticas) → prioridad de candidata (la doctrina
     existente); incomparable → contradicción, jamás una elección por prioridad. Tras elegir, `analyze`
     final sobre la ganadora para que TODOS los campos salgan de ella (jamás un "run
     quimera" de campos mezclados).
5. **Salida en modo slug** (~:817-839): fila nueva `raíz:` SIEMPRE (también mono-raíz)
   con la ruta física ganadora — el fallback `DEFAULT_ROOT` (EVR_N=0) se canonicaliza
   por la MISMA maquinaria física que las candidatas, y cuando el report existe solo por
   plan/rama encontrados en otras candidatas (sin `.tandem`), la fila lo dice:
   `raíz: <física> (sin estado .tandem)` — jamás nombra como dueña a una raíz que no
   posee la evidencia; con EVR_N≥2 consistentes, anexo
   `· evidencia también en <otra raíz> (fase: <fase>)` — la raíz rancia visible, jamás
   como `fase:` a secas. Con CONTRA=1: stdout VACÍO; stderr:
   `tandem: evidencia contradictoria para "<slug>" entre raíces de estado:`, una línea
   `  - <raíz> — fase: <fase>` por raíz, una línea nombrando el hecho irreconciliable
   (p.ej. "thread de plan-review distinto entre raíces") y cierre "resolver a mano — sin
   paso siguiente automático" (sin el literal `next:`, para el negativo); exit 2.
6. **Modo lista** (~:781-806): `print_runs` vía `resolve_slug`; un slug contradictorio se
   lista como `<slug> — contradictorio entre raíces`; exit sigue 0 (la lista es
   panorámica; el detalle se pide en modo slug). El caso existente de status-list (mismo
   log idéntico en ambas raíces, sin hechos de identidad) sigue listándose UNA vez.
7. **Contratos documentados:** cabecera de exit codes del script (`2 = sin evidencia, o
   contradicción irreconciliable entre raíces (ambas en stderr)`); `skills/status/SKILL.md`
   — fila `raíz:` en la tabla, exit codes, y párrafo de contradicción multi-raíz junto al
   de `contradictorio — …` existente.
8. **Tests:**
   - `tests/status-multi-root.test.sh` (NUEVO, autodescubierto): arnés ro_snap/status_in
     de status-phases + stub codex. (A) caso del backlog: mismo slug en principal y
     worktree enlazado, principal más avanzado, sesión CLAUDE_PROJECT_DIR=worktree →
     fase del principal, `raíz:` física del principal, la fase rancia solo como anotación
     (contra el código actual FALLA: hoy gana el worktree — el fix muerde); (B) inverso —
     más avanzado en la raíz prioritaria → también gana (decide el rango, no el orden);
     (C) contradicción — thread ids distintos para la misma clave → exit 2, stdout vacío,
     stderr con ambas raíces y fases, negativos `next:` y `/tandem:`; (D) estado idéntico
     duplicado → exit 0, gana la prioritaria, sin contradicción; (E) symlink → una sola
     raíz (dedupe físico), sin anotación; (F) modo lista con slug contradictorio →
     `contradictorio entre raíces`, exit 0, una línea; (G) MISMO thread id con progreso
     distinto (turno 1 REVISE en la prioritaria, turno 2 APPROVED en la otra) → gana el
     progreso, next del veredicto nuevo; (G2) mismo thread, MISMO turno, respuesta
     completada en una copia y ausente en la otra → gana la completada; (G3) mismo
     thread, mismo turno, DOS verdicts completados distintos → contradicción exit 2;
     (H) Opus mismo linaje, terminal de ronda 0 en una copia y running de ronda 1 en la
     otra → gana la ronda 1 (continuation_rounds primero); (H2) misma ronda, terminal vs
     running → gana terminal; (H3) revisiones terminales iguales con sentinels distintos
     → contradicción exit 2; (H4) progreso Opus INVÁLIDO en la copia prioritaria (rondas negativas o fraccionarias,
     status desconocido, sentinel desconocido) contra una válida IMPLEMENTATION_COMPLETE
     no-prioritaria → GANA la válida y su next (dominancia), sin diagnósticos de
     aritmética en stderr y sin split-brain; ambas inválidas → prioridad;
     (N) rama SOLO en un repo candidato no-default → la raíz dueña de la rama, no el
     repo del DEFAULT_ROOT; (I) Opus con
     `plan_hash` o `branch` distintos entre raíces → contradicción exit 2 (con
     `agent.id` distinto y mismo linaje NO hay contradicción — es la forma de una
     recovery); ambos lados de I con linaje VÁLIDO (OP_ID_VALID=1), y control de linaje
     CORRUPTO en la raíz PRIORITARIA contra linaje válido IMPLEMENTATION_COMPLETE en la
     otra → sin contradicción, GANA la raíz válida y su next (dominancia de linaje);
     ambos corruptos → prioridad; (J) registro
     de aprobación VÁLIDO en una raíz y CORRUPTO con sha crudo distinto en la otra → NO
     es contradicción: el corrupto degrada como siempre y la válida gana; (K) dual-root
     con evidencia SOLO de thread (sin log) → detectada (claves precomputadas); (L) modo
     lista multi-slug donde claves rancias del slug anterior perderían raíces del
     siguiente; (M) symlink/fallback con SOLO plan en otra candidata → `raíz:` física
     canonicalizada con `(sin estado .tandem)`. Cierre: prueba read-only byte a byte en
     cada invocación y cero llamadas al stub codex; test de cada par adyacente de la
     escalera de rangos (12 fases, 11..0 únicos).
   - `tests/status-phases.test.sh`: la sección dual-root existente (slug ajeno en el
     worktree) gana la aserción de la fila `raíz:` apuntando a la ruta física del
     principal.
   - `tests/skill-status-contract.test.sh`: anclas positivas para la fila `raíz:`, la
     contradicción con exit 2 y "sin paso siguiente automático".
9. **Metadatos (orquestador, fuera de este plan):** plugin.json → 0.24.0, CHANGELOG,
   BACKLOG M17 → hecha, fila de la cola.

## Key decisions & tradeoffs

- **Contradicción = hechos de IDENTIDAD solapados que difieren** (thread id por clave,
  plan_commit validado, sha terminal verificado, linaje Opus inmutable) — o progreso
  incomparable con identidad igual (verdicts distintos al mismo turno, sentinels
  distintos a la misma revisión terminal) — NUNCA mera divergencia de fase: la divergencia de fase es
  exactamente la forma del estado rancio legítimo (una copia atrasada del mismo run, o un
  run cuyo plan-review corrió en el worktree — `_common.sh` documenta que el thread state
  se queda donde corrió; el split de raíces es situación DISEÑADA). Un run honesto no
  puede tener dos thread ids para la misma clave ni dos plan_commit: eso es split-brain y
  merece parar. Los "detalles blandos" con la misma identidad ya no se reconcilian por
  prioridad: pasan por el orden de revisión de arriba, y lo genuinamente incomparable es
  contradicción.
- **La contradicción va a stderr con exit 2 y stdout vacío**, no como report con fase
  "contradictoria": un report tendría que elegir raíz para cada una de las otras filas —
  exactamente el bug de enmascaramiento; el precedente del repo es stderr+2 = "no hay
  report fiable". Coste: exit 2 se ensancha (antes solo "sin rastro") — documentado.
- **`FASE_RANK` dentro de las ramas de la escalera**, no en mapa paralelo: toca ~11 ramas
  pero elimina estructuralmente la posibilidad de que el orden de reconciliación derive
  del orden real.
- **Empate de rango → orden de revisión explícito, prioridad solo para copias
  idénticas:** el rango es de FASE y dos copias del mismo run comparten fase con progreso
  distinto — elegir por prioridad reproduciría el next equivocado que M17 arregla. Orden:
  turno mayor; mismo turno, respuesta completada > ausente; verdicts completados
  distintos a mismo turno = contradicción. Opus: continuation_rounds primero, luego
  terminal > running dentro de la misma ronda; terminales iguales con sentinels distintos
  = contradicción. TODO igual → prioridad (pinna el caso 'g' de status-list). Solo hechos
  INMUTABLES participan en la identidad (threads, plan_commit validado, sha terminal
  verificado, y el linaje Opus plan_hash/branch/agent_type — nunca
  agent.id, que una recovery legítima renueva, ni task_id/status/sentinel).
- **Identidad solo VALIDADA:** los hechos comparados salen del propio analyze tras su
  modelo de validez (PLAN_COMMIT solo de registro válido, terminal solo verificado por
  git) — un registro corrupto queda no-comparable y conserva la degradación que los tests
  de M11/M16 ya anclan; jamás un split-brain falso por basura.
- **`raíz:` SIEMPRE impresa en modo slug:** una fila más a cambio de forma determinista y
  de que el usuario siempre vea de dónde sale la verdad.
- **`analyze` una vez por raíz con evidencia + una final sobre la ganadora**, no fusión
  campo a campo: lecturas repetidas baratas a cambio de no inventar un run quimera.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/tandem-status.sh` | pwd -P, FASE_RANK en escalera, analyze por raíz, resolve_slug con sonda de identidad, fila raíz:, rama de contradicción, print_runs, cabecera |
| `tests/status-multi-root.test.sh` | NUEVO — casos A-F + read-only + cero codex |
| `tests/status-phases.test.sh` | Aserción de `raíz:` en la sección dual-root existente |
| `tests/skill-status-contract.test.sh` | Anclas de raíz:/contradicción/sin-paso |
| `skills/status/SKILL.md` | Fila raíz:, exit codes, párrafo de contradicción multi-raíz |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` | v0.24.0 — orquestador |

## Acceptance & proof

- Caso del backlog (A): dual-root con el principal más avanzado y sesión anclada al
  worktree → fase y report del principal; la raíz rancia solo como anotación. Contra el
  código actual este caso FALLA — prueba de que el fix muerde.
- Contradicción (C): thread ids distintos para la misma clave → exit 2, stdout vacío,
  stderr con ambas raíces y ambas fases, sin `next:` ni `/tandem:` en ninguna salida.
- Consistencia (B/D/E): rango manda sobre orden; duplicado idéntico → prioritaria sin
  drama; symlink → una sola raíz física.
- Modo lista (F): `contradictorio entre raíces`, exit 0, una línea; los casos existentes
  de status-list (unión dedupe, 'g' una vez) siguen verdes SIN tocar ese test.
- Toda invocación nueva pasa ro_snap byte a byte y cero llamadas codex; status-degradation
  sigue verde (stderr vacío en exit 0, guardas anti-heredoc, casos sin jq/git).

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- Exit 2 ensanchado puede sorprender a un consumidor que lo trate como "typo": los únicos
  consumidores (SKILL de status y run) se actualizan; el mensaje se distingue del de "sin
  rastro".
- `pwd -P` cambia rutas impresas en setups con symlinks — cosmético; ningún test existente
  aserta esas rutas en lógico.
- `analyze` por raíz multiplica lecturas en modo lista (slugs × raíces con evidencia) —
  acotado (≤4 candidatas, realista 1-2) para una herramienta de orientación.
- Falso positivo si alguien copia `.tandem/` a mano y regenera un thread en una raíz — es
  exactamente el split-brain que debe parar a un humano; el mensaje nombra el hecho.
- Regresión en status-phases/degradation por la fila nueva: ambos asertan filas puntuales
  (assert_matches), no cuentan líneas del report en modo slug (verificado); el único
  conteo de líneas es en modo lista, cuyo formato no cambia.

## Out of scope

- `collect_runs` y la unión del modo lista (ya multi-raíz con dedupe correcto).
- La resolución de raíz propia de `review-range.sh` y `worktree-root.sh` (contrato propio,
  anclado por sus tests).
- Statusline y heartbeats (HB_ROOT ya se re-ancla al principal por diseño).
- `plan-approve.sh`; M16 (ya mergeada en esta rama) y M18.
- Fusión campo a campo de evidencia entre raíces.
- Metadatos (orquestador).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Qué es contradicción?** → Hechos de identidad divergentes (thread ids, plan_commit
   validado, sha terminal verificado, linaje Opus inmutable) o progreso incomparable con
   identidad igual; la mera divergencia de fase es estado rancio legítimo.
2. **¿Report con fase "contradictoria" o stderr+2?** → stderr+2 con stdout vacío (el
   precedente del repo; un report elegiría raíz para el resto de filas).
3. **¿Modo lista con contradicción?** → `contradictorio entre raíces`, exit 0 (la lista
   es panorámica; el detalle en modo slug).
4. **¿Rama?** → `tandem/status-multi-root` apilada sobre `tandem/status-approval-proof`
   (misma familia de ficheros — apilar evita colisiones), con `plan-approve.sh`.
5. **¿Versión?** → 0.24.0; metadatos del orquestador tras la implementación.
