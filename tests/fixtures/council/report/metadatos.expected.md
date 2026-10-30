# Metadatos del consejo 2026-10-19-report

- Creado: 2026-10-19T08:00:00Z · modo: web · tope de rondas: 2 · rondas completas: 2
- Perfil: crítico (max: líder, Fable y Astra)
- Estado: CONSENSO en la ronda 2

## Letras (reveladas al final)

| Letra | Asiento | Modelo / effort | Evidencia |
| --- | --- | --- | --- |
| A | líder | claude-opus-5-5 / max | autodeclarado y confirmado en el gate; no medido |
| B | Astra (Codex) | gpt-6-astra/max | meta.json de cada turno (council-2026-10-19-report-g1 t1, council-2026-10-19-report-g1 t2, council-2026-10-19-report-g2 t1, council-2026-10-19-report-g2 t2, council-2026-10-19-report-g2 t3) |
| C | Fable (Claude) | claude-fable-5-1, claude-fable-5-1-20261001 / max | modelos y esfuerzos de cada captura del transcript (agente: tandem:council-fable); hay capturas transcritas a mano (modelo no verificado) |

## Turnos de Astra

- propose a1 sustantivo — done · council-2026-10-19-report-g1 t1 · role=council model=gpt-6-astra effort=max sandbox=read-only
- cross a1 sustantivo — failed · council-2026-10-19-report-g1 t2 · role=council model=gpt-6-astra effort=max sandbox=read-only
- cross a2 sustantivo — done (recuperado) · council-2026-10-19-report-g2 t1 · role=council model=gpt-6-astra effort=max sandbox=read-only
- round-1 a1 sustantivo — done · council-2026-10-19-report-g2 t2 · role=council model=gpt-6-astra effort=max sandbox=read-only
- round-1 a1 recordatorio — interrupted · council-2026-10-19-report-g2 t-
- round-2 a1 sustantivo — done · council-2026-10-19-report-g2 t3 · role=council model=gpt-6-astra effort=max sandbox=read-only

## Capturas de Fable

- propose a1 sustantivo — capturado, modelo verificado: claude-fable-5-1
- cross a1 sustantivo — capturado, modelo verificado: claude-fable-5-1
- round-1 a1 sustantivo — transcrito, modelo no verificado
- round-1 a1 recordatorio — capturado, modelo verificado: claude-fable-5-1
- round-2 a1 sustantivo — capturado, modelo verificado: claude-fable-5-1-20261001

## Rondas y veredictos

- última ronda completa: 2 — B APPROVED · C APPROVED

## Anomalías

- recordatorio: round-1 letra C (a1)
- transcripción a mano (--manual): round-1 a1 sustantivo — modelo no verificado
- reconstrucción: cross letra B (a2, con historial)
- generaciones del hilo de Astra: council-2026-10-19-report-g1, council-2026-10-19-report-g2
- agentes de Fable registrados: 2 (reconstrucciones)
- turno de Astra cross a1 sustantivo: failed — turno sin recibo: rechazado o cortado
- turno de Astra round-1 a1 recordatorio: interrupted — señal antes de lanzar: no hubo turno
- lectura fuera de alcance (fable, cross a1): docs/council/x/1-propuestas/B.md · docs/council/x/prompts/cross-B.a1.md
- lectura fuera de alcance (astra, round-1 a1): cat .tandem/state/council/runs/x/sealed/cross.md

## Tokens

- Astra: input_tokens=13200 cached_input_tokens=9900 output_tokens=1320 reasoning_output_tokens=125 (5 ficheros t<N>.usage.json de 2 generación(es), cada uno una vez, también los de turnos fallidos o interrumpidos)
- Fable: input_tokens=10 cache_read_input_tokens=74 cache_creation_input_tokens=20 output_tokens=28 (4 capturas, deduplicadas por message.id) — COTA INFERIOR: 3 de 13 mensajes del transcript sin usage definitivo (su última línea no trae stop_reason)
- líder: no medido
