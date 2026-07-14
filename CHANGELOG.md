# Changelog

## 0.1.0 — 2026-07-14

Primera versión del plugin `tandem`.

- Skills: `run`, `plan`, `implement`, `review`, `ask`, `doctor`.
- Scripts compartidos endurecidos (`codex-start/resume/show/reset/doctor` + `_common`): sandbox fijado por rol y re-fijado en cada resume, estado por proyecto en `.tandem/`, salidas por turno, detección del fallback silencioso de `resume`, errores visibles, portable a macOS/BSD (bash 3.2).
- Política de modelos: Sol `xhigh` para review/ask (read-only), Luna `high` para implementación (workspace-write), `TANDEM_CRITICAL=1` para implementar con Sol.
- Documentación de arquitectura y roadmap de migración a Codex MCP.
