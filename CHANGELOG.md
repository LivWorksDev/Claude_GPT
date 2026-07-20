# Changelog

## 0.5.0 — 2026-07-20

- Heartbeat visible desde worktrees: los turnos lanzados dentro de un worktree enlazado (`TANDEM_WORKTREE`) escribían el heartbeat en el `.tandem/` del worktree y la status line, que mira el checkout principal, nunca lo veía. Ahora `state_init` resuelve el repo principal vía `git rev-parse --git-common-dir` y el heartbeat va siempre allí (el estado de hilos sigue donde corrió el turno); la status line hace además el fallback inverso para sesiones abiertas dentro de un worktree.
- Actividad en vivo en la status line: el heartbeat incluye la ruta del `events.ndjson` del turno y, mientras `running`, la línea 2 muestra qué hace Codex ahora mismo (`exec pytest -q…`, `edit models.py`, `thinking…`, `writing reply…`) leyendo el último evento con lectura acotada (`tail -c`) tolerante a líneas parciales.
- Milestones en vivo en el panel de shell: `codex-start/resume` pasan el NDJSON por `tee` + `stream_milestones`, que narra en stdout cada hito (`» exec …`, `✓ ok` / `✗ exit N`, `» edit a, b +N more`, `» turn done — tokens in/out`, `✗ turn failed`) — el panel "Shell details" de un turno en background se convierte en un feed de progreso. `PIPESTATUS[0]` preserva el exit code real de codex (un fallo del filtro nunca se disfraza de fallo de Codex) y el filtro drena el stream si muere para no matar a codex con SIGPIPE.
- Fix del transporte de campos en la status line: `@tsv` + `IFS=$'\t'` colapsaba campos vacíos (el tab es whitespace para `read`), desplazando los siguientes una posición — p.ej. con `verdict` nulo la ruta de events acababa en la variable equivocada, y sin `effort` el % de contexto se corría. Sustituido por unit separator (`\x1f`), que no colapsa.

## 0.4.0 — 2026-07-20

- Status line (`scripts/statusline.sh`): modelo, effort, porcentaje de contexto con barra, coste y rama en la primera línea; la puerta de Codex en la segunda (rol, modelo, effort, turno, sandbox, cronómetro, veredicto), coloreada por desenlace y visible solo cuando hay actividad reciente. Degrada a una línea corta si falta `jq`, el payload es inválido o el proyecto no tiene `.tandem/`.
- Heartbeat `.tandem/state/current.json`: `codex-start.sh`/`codex-resume.sh` marcan cada turno como `running` y lo cierran con `done` + veredicto extraído del sentinel de la respuesta. Un `trap EXIT` cubre `die`, Ctrl-C y crashes dejando `failed`; la status line detecta además procesos huérfanos vía pid. `codex-reset.sh` limpia el heartbeat solo si describe el target reseteado.
- Instalación portable de la status line (`/tandem:statusline` + `scripts/statusline-install.sh`): Claude Code no deja a un plugin declarar la status line principal, así que la skill la instala con consentimiento — shim en `~/.claude/tandem-statusline.sh` que re-resuelve el script del plugin en cada render (sobrevive a actualizaciones, fallback mínimo si tandem desaparece) + entrada `statusLine` en el `settings.json` del usuario (atómico, backup, exit 2 ante una statusLine ajena salvo `--force`, y rehúsa tocar un settings corrupto). `codex-doctor.sh` informa del estado de la integración. Respeta `CLAUDE_CONFIG_DIR`.

## 0.3.0 — 2026-07-14

- Respuestas de Codex por turno: los scripts guardan `state/<clave>.t<N>.reply.txt` en cada turno (el historial completo del debate queda legible por ronda); `<clave>.last.txt` pasa a ser un puntero de conveniencia que solo se actualiza tras superar todas las comprobaciones de éxito.
- Registro durable del review (opcional): `tandem:review` puede promocionar el veredicto y el resumen del debate a `docs/reviews/<slug>.md` en el commit de aprobación — `TANDEM_PROMOTE_REVIEWS=1` siempre, `0` nunca, sin definir se ofrece en el gate humano.

## 0.2.1 — 2026-07-14

- Punto ciego de archivos nuevos corregido (detectado en el test end-to-end del pipeline): `git diff HEAD` no muestra archivos sin trackear, así que los prompts del code review y los pasos de verificación de `implement`/`review` ahora exigen leer directamente cada entrada `??` de `git status -s`, y el context file del review lista los archivos cambiados marcando los untracked.

## 0.2.0 — 2026-07-14

- Política de modelos "solo Sol" para máximo desempeño: la implementación pasa de `gpt-5.6-luna` a `gpt-5.6-sol` (effort `high`); `TANDEM_CRITICAL=1` ahora sube el effort de implementación a `xhigh` en lugar de cambiar de modelo. Review/ask siguen en Sol `xhigh`.

## 0.1.0 — 2026-07-14

Primera versión del plugin `tandem`.

- Skills: `run`, `plan`, `implement`, `review`, `ask`, `doctor`.
- Scripts compartidos endurecidos (`codex-start/resume/show/reset/doctor` + `_common`): sandbox fijado por rol y re-fijado en cada resume, estado por proyecto en `.tandem/`, salidas por turno, detección del fallback silencioso de `resume`, errores visibles, portable a macOS/BSD (bash 3.2).
- Política de modelos: Sol `xhigh` para review/ask (read-only), Luna `high` para implementación (workspace-write), `TANDEM_CRITICAL=1` para implementar con Sol.
- Documentación de arquitectura y roadmap de migración a Codex MCP.
