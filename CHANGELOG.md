# Changelog

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
