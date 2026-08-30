# Review — doctor-autonomous (M34, v0.34.0)

- **Fecha:** 2026-08-30
- **Plan:** `docs/plans/doctor-autonomous.plan.md` (M34 — `doctor --autonomous`,
  preflight frío del modo desatendido; origen: revisión del modo autonomous con el
  mantenedor, 2026-08-29)
- **Rama:** `tandem/doctor-autonomous` off `tandem/implement-write-audit` (base
  f01830a, v0.33.0 — apilada porque M25 estaba sin mergear y la versión/CHANGELOG
  colisionarían desde main; orden de merge: implement-write-audit →
  doctor-autonomous)
- **Modo:** AUTONOMOUS end-to-end (`TANDEM_AUTONOMOUS=1`) — primer run completo
  del pipeline en desatendido; gates humanos sustituidos por la política
  APPROVED+gate-verde, asunciones registradas en el plan (transporte sol por
  agente crítico no registrado en la sesión, base apilada, test dedicado)
- **Gate:** lint: OK (shellcheck scripts/+tests/ clean) · typecheck: n/a (bash) ·
  tests: 89 passed, 0 failed (incluye `tests/doctor-autonomous.test.sh` nuevo) ·
  actionlint: OK · proof (`bash tests/verify.sh`): OK — re-ejecutado tras el fix
  del Major del code review
- **Plan review (Sol, xhigh, hilo persistente):** 5 rondas → `VERDICT: APPROVED`
- **Code review (Sol, xhigh, hilo fresco sin contexto previo):** 2 rondas →
  `VERDICT: APPROVED` (1 Major en R1, corregido por el orquestador y verificado)
- **Transporte de implementación:** Sol a xhigh (`TANDEM_CRITICAL=1`), sandbox
  `workspace-write` sin red. Un turno, `IMPLEMENTATION_COMPLETE`, sin
  desviaciones. **Estreno en producción de las barreras M25:** snapshot+guard
  publicados antes del lanzamiento, `check` con censo en OK (sin WARN) y `close`
  tras gate verde — ciclo de vida completo observado de verdad.

## Hallazgos y disposiciones (condensado)

### Plan review — 5 rondas, 12 hallazgos, todos aceptados

- **R1 `REVISE` — 3 P1 + 3 P2:** (P1-1) `TANDEM_TRANSPORT` fuera del preflight —
  un `mcp` heredado responde 64 en el primer lanzamiento tras un doctor verde →
  gate `{unset,exec}`; (P1-2) un repo unborn certificaba limpio en falso →
  exigir `git rev-parse --verify HEAD`; (P1-3) aceptación internamente
  insatisfacible (cero turnos en TODO caso vs. combinar con `--smoke`) → acotada;
  (P2-1) `TANDEM_AUTONOMOUS` tri-estado; (P2-2) el sandbox de tests no es repo —
  fixture explícito + caso de anclaje desde otro cwd (caza implementaciones con
  `$PWD`); (P2-3) el «byte a byte» del default no estaba probado → usage completo
  asertado y garantía acotada a lo demostrado.
- **R2 `REVISE` — 1 P1 + 2 P2:** (P1-1) `TANDEM_EXEC_TIMEOUT_SECONDS` sin
  comprobar (misma clase) → validada con las reglas del wrapper; el orquestador
  amplió la clase con `TANDEM_TURN_EFFORT` verificándolo en fuente (un export
  inválido mata los resumes 2+ con 64); (P2-1/P2-2) restos contradictorios del
  Out of scope y el Approach alineados con la aceptación acotada.
- **R3 `REVISE` — 2 P1:** (P1-1) un `TANDEM_TURN_EFFORT` exportado VÁLIDO (`low`)
  degrada en silencio las rondas sustantivas → bajo `--autonomous` debe estar
  UNSET, todo valor definido falla con mensaje propio; (P1-2) `TANDEM_CODEX_CWD`
  heredada → unset o resolviendo al project root; un directorio ajeno haría que
  el revisor inspeccionara otro repositorio.
- **R4 `REVISE` — 1 P2:** la equivalencia física de `TANDEM_CODEX_CWD` no tenía
  caso positivo de symlink (una igualdad literal pasaría el PROOF) → caso añadido;
  atribución de `pwd -P` corregida como regla propia del doctor
  (`codex_cwd_validate` no normaliza).
- **R5 `APPROVED`** — «internally consistent and its proof covers the identified
  failure modes».

### Code review — 2 rondas

- **R1 `REQUEST_CHANGES` — 1 Major, ACEPTADO y corregido por el orquestador:**
  la línea añadida al preflight de `skills/run/SKILL.md` usaba `$SCRIPTS`, que esa
  skill nunca define (la ruta se resolvería a `/codex-doctor.sh`) → forma completa
  vía `${CLAUDE_SKILL_DIR}`, más aserción de contrato en el test (positiva y
  negativa). Gate re-ejecutado en verde tras el fix.
- **R2 `APPROVED`** — Major verificado como Fixed, sin hallazgos nuevos.
