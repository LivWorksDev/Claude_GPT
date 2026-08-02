# Fixtures reales de `codex mcp-server` 0.144.4

Capturados del servidor REAL el 2026-08-02 durante la auditoría de la Fase 2
(`docs/audits/fase2-mcp-parity.md`), hablando ndjson JSON-RPC por stdio con un
`CODEX_HOME` aislado y vacío. **Cero turnos de modelo**: solo `initialize` y `tools/list`,
que el servidor responde sin autenticar.

| Fichero | Qué es |
| --- | --- |
| `handshake-raw.jsonl` | las dos respuestas crudas, byte a byte, tal como llegaron |
| `initialize.json` | la respuesta de `initialize` (capabilities, protocolVersion, serverInfo) |
| `tools-list.json` | la respuesta de `tools/list`: los inputSchema completos de `codex` y `codex-reply` |
| `codex-version.txt` | `codex --version` de la CLI auditada |

Existen para que la suite no pueda quedar verde contra un stub que inventa formas de
frame: el stub y el parser se contrastan con estos bytes reales. Si el servidor upstream
cambia el contrato (la interfaz MCP está declarada experimental), el job semanal de drift
lo detecta comparando un handshake real —también sin gasto— contra `tools-list.json`.

Regenerar solo tras auditar la versión nueva: estos ficheros son la referencia de
**0.144.4**, no "lo último que respondió la CLI".
