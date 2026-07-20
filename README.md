# tandem — Fable orquesta, Codex ejecuta y ataca

Plugin de Claude Code que convierte a **Claude (Fable 5)** en orquestador y árbitro, y a **OpenAI Codex** (GPT-5.6 Sol) en implementador y revisor adversarial, todo desde una sesión normal de Claude Code:

```
Fable planifica → Sol ataca el plan (read-only, hilo persistente)
    → gate humano → Sol implementa (workspace-write, rama dedicada)
    → Fable lee el diff completo y ejecuta el testing gate
    → un Sol NUEVO revisa el código (sin contexto previo)
    → gate humano → Fable hace el commit (Codex nunca commitea)
```

## Instalación

Requisitos: [Codex CLI](https://github.com/openai/codex) con login activo (`npm install -g @openai/codex@latest && codex login`), `jq`, `git`.

**Como plugin (recomendado):**

```bash
# añade este repo como marketplace e instala
claude plugin marketplace add <ruta-o-git-de-este-repo>
claude plugin install tandem@claude-gpt
```

**Para desarrollo local:**

```bash
claude --plugin-dir /ruta/a/este/repo
```

Verifica el toolchain con `/tandem:doctor`.

## Skills

| Skill | Qué hace |
| --- | --- |
| `/tandem:run` | Pipeline completo: plan → red-team → implementación → verificación → review → commit |
| `/tandem:plan` | Entrevista + plan + revisión adversarial de Sol hasta APPROVED (cap de rondas) |
| `/tandem:implement` | Codex implementa el plan aprobado; Fable verifica el diff y ejecuta el testing gate |
| `/tandem:review` | Code review final por un hilo Sol nuevo e independiente |
| `/tandem:ask` | Segunda opinión de Sol sobre cualquier tema, con follow-ups en el mismo hilo |
| `/tandem:doctor` | Diagnóstico del toolchain (codex, login, jq, política de modelos, status line) |
| `/tandem:statusline` | Instala/desinstala la status line (modelo, contexto, coste + puerta Codex en vivo) |

## Status line

Debajo del prompt puedes ver a la vez la sesión de Claude y lo que está haciendo Codex:

```
◈ Fable 5 xhigh✳ · ctx 34% ▓▓▓░░░░░░░ · $0.42 · mi-proyecto ⑂ tandem/auth-refactor
⚙ codex gpt-5.6-sol · implement high · t3 · workspace-write · 1m42s · auth-refactor
```

La segunda línea solo aparece mientras hay un turno de Codex en vuelo o recién terminado (15 min), y colorea el desenlace: verde `APPROVED`/`IMPLEMENTATION_COMPLETE`, ámbar `REVISE`, rojo `REQUEST_CHANGES` o fallo, gris si el proceso murió sin dejar rastro.

**Instalación: `/tandem:statusline`** (o `bash scripts/statusline-install.sh`). Claude Code no permite que un plugin aporte la status line principal (el `settings.json` de un plugin solo admite `agent` y `subagentStatusLine`), así que la skill la instala con tu consentimiento: escribe un shim en `~/.claude/tandem-statusline.sh` que re-resuelve el `statusline.sh` del plugin en cada render — sobrevive a las actualizaciones del plugin (cuya ruta de caché cambia por versión) y degrada a una línea mínima si tandem desaparece — y añade la entrada `statusLine` a tu `settings.json` (escritura atómica, backup en `settings.json.tandem-backup`, y nunca pisa una statusLine ajena sin `--force`). `refreshInterval: 2` mantiene vivo el cronómetro mientras un `codex exec` bloquea. `/tandem:statusline uninstall` lo deshace; `/tandem:doctor` comprueba si está instalada.

## Política de modelos y permisos

| Rol | Modelo (default) | Effort | Sandbox |
| --- | --- | --- | --- |
| Revisor / consultor | `gpt-5.6-sol` | `xhigh` | `read-only` (fijado, no sobreescribible) |
| Implementador | `gpt-5.6-sol` | `high` | `workspace-write` (fijado, no sobreescribible) |
| Implementador crítico (`TANDEM_CRITICAL=1`) | `gpt-5.6-sol` | `xhigh` | `workspace-write` |

Por encima de `xhigh` existen `max` y `ultra`; para una revisión final especialmente delicada puedes usar `TANDEM_REVIEW_EFFORT=ultra` puntualmente.

Overrides por entorno: `TANDEM_REVIEW_MODEL`, `TANDEM_REVIEW_EFFORT`, `TANDEM_IMPLEMENT_MODEL`, `TANDEM_IMPLEMENT_EFFORT`, `TANDEM_PLAN_ROUNDS`, `TANDEM_CR_ROUNDS`, `TANDEM_IMPL_ROUNDS`, `TANDEM_WORKTREE`, `TANDEM_PROMOTE_REVIEWS` (`1` siempre / `0` nunca / sin definir: se ofrece en el gate). Los sandboxes no se pueden sobreescribir y `danger-full-access`/`--yolo` no se usan nunca.

## Invariantes de seguridad

- El revisor nunca escribe; el implementador nunca sale del workspace.
- El sandbox se re-fija en **cada** reanudación (`codex exec --sandbox … resume …` + `-c sandbox_mode=…`): nunca se hereda del `config.toml` del usuario.
- Árbol git limpio obligatorio antes de delegar escritura; rama dedicada siempre; worktree opcional.
- Thread IDs persistidos en `.tandem/state/` (sobreviven a compactaciones de la sesión de Claude).
- Loops acotados con el deadlock como resultado legítimo: los desacuerdos se muestran, no se maquillan.
- Codex jamás hace commit; Fable solo commitea tras la aprobación humana del diff.
- Errores de Codex visibles (stderr capturado por turno, exit codes verificados, detección del fallback silencioso de `resume`).

## Estado y artefactos

- `docs/plans/<slug>.plan.md` — planes (versionados).
- `docs/reviews/<slug>.md` — registro final del review (versionado, opcional — ver `TANDEM_PROMOTE_REVIEWS`).
- `.tandem/` — estado por proyecto, auto-gitignorado y por-feature (clave = target + checksum; una feature nueva nunca pisa el estado de otra): hilos, y prompt/respuesta/eventos POR TURNO (`state/…tN.*`), log append-only del debate (`log/`).
- `.tandem/state/current.json` — heartbeat de la status line (rol, modelo, effort, sandbox, turno, pid, estado, veredicto). Artefacto de presentación: se escribe de forma atómica y su fallo nunca aborta un turno.

## Arquitectura y roadmap

Esquema completo, decisiones y la migración prevista a Codex MCP en [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Créditos

Diseño inspirado en los patrones de [grill-me-codex](https://github.com/chaseai-yt/grill-me-codex) (MIT) — entrevista, veredicto de última línea, gates humanos, deadlock honesto — y en el reparto de roles de [TRIP-workflow](https://github.com/PiLastDigit/TRIP-workflow) (Sol revisa / Luna implementa, hilos por target, anti-nitpick). Todo el código y los prompts de este repo son implementaciones originales. Licencia MIT.
