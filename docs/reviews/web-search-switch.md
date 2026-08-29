# Review — web-search-switch (M26, v0.31.0)

- **Fecha:** 2026-08-29
- **Plan:** `docs/plans/web-search-switch.plan.md` (M26 — interruptor de
  confidencialidad para `web_search`; origen: informe de campo 2026-08-21, hallazgo
  A3 + enmienda E-A3)
- **Rama:** `tandem/web-search-switch` off `main` (base e6c30df, v0.30.0)
- **Gate:** lint: OK (shellcheck v0.10.0, scripts/+tests/ clean) · typecheck: n/a
  (bash; `bash -n` en verde) · tests: 84 passed, 0 failed (incluye
  `tests/web-search-switch.test.sh` nuevo) · actionlint: OK · proof
  (`bash tests/verify.sh`): OK
- **Plan review (Sol, xhigh, hilo persistente):** 2 rondas → `VERDICT: APPROVED`
- **Code review (Sol, xhigh, hilo fresco sin contexto previo):** 1 ronda →
  `VERDICT: APPROVED`, cero hallazgos
- **Transporte de implementación:** Sol a xhigh (`TANDEM_CRITICAL=1`), sandbox
  `workspace-write`; el gate humano eligió este transporte porque el agente
  `implementer-critical` de Opus no estaba registrado en la sesión — sin
  degradación silenciosa. CHANGELOG y version bump escritos por el orquestador
  (prohibidos al implementador por template) → `IMPLEMENTATION_PARTIAL` resuelto
  por takeover.

## Hallazgos y disposiciones (condensado)

### Plan review — ronda 1: `REVISE`, 2 hallazgos P2, ambos ACEPTADOS

- **P2-1 — faltaba un consumidor real de `codex_pins()`:** `mcp-probe.sh` gasta
  hasta tres turnos reales sin pasar por el validador propuesto; el plan lo omitía.
  Disposición: entra en alcance (validación en posición usage-error antes de
  `need_codex` y de crear estado) con tests de gating (vacía/bogus → 64 sin
  tools/call, sin exec, sin estado) y de propagación (`--spend` con `off` → pin en
  el registro del stub). La propagación se fija sobre el stub y no sobre el
  config.toml efímero del probe: es el punto de aserción idiomático de la suite.
- **P2-2 — contradicción aceptación/approach:** «sin la variable NADA cambia»
  chocaba con el banner incondicional de swarm. Disposición: el banner queda
  siempre-visible (E-A3: el estado efectivo se observa en el run vivo, también en
  el default) y la aceptación se estrecha al contrato real — argv y política
  intactos; el ÚNICO cambio de salida del default es el campo final
  `web_search=on` del banner, declarado intencional y fijado por aserción positiva.

### Plan review — ronda 2: `APPROVED`

Ambos hallazgos dados por resueltos; sin hallazgos nuevos.

### Code review — ronda 1: `APPROVED`

> No findings. The implementation is faithful to the plan, preserves defaults,
> validates fail-closed before dependencies/state, and has appropriate regression
> coverage including the untracked test.

## Contabilidad del run (ChatGPT quota, tokens)

| Fase | Turnos | In | Out |
| --- | --- | --- | --- |
| Plan review | 2 | 4 606 230 | 29 114 |
| Implement (Sol xhigh) | 1 | 10 669 633 | 25 648 |
| Code review | 1 | 970 547 | 8 078 |
| **Total** | **4** | **16 246 410** | **62 840** |
