# Canario real de `/tandem:council` (M39, v0.36.0)

- **Fecha:** 2026-10-18 → 2026-10-19
- **Plugin:** tandem 0.36.0 instalado en el scope de usuario (commit fb1741e, rama `tandem/council`).
- **Dónde:** una sesión nueva de la app de escritorio, abierta en una carpeta vacía fuera de
  cualquier repo (`~/Documents/LIVWORKS/council-canario-2026-10-18`).
- **Líder:** Opus 5.5 en max.
- **Idea:** la del usuario (estrategia de redes de Recap90 con la entrada del Real Madrid).
- **Run:** `2026-10-18-recap90-redes-madrid`, en modo web, con tope de 4 rondas.
- **Letras:** A = Fable, B = Astra, C = líder.
- **Verificación:** la sesión del canario informó de su propia evidencia. La sesión de origen
  la volvió a comprobar contra los ficheros; los valores de abajo salen de esa segunda pasada.

## Veredicto

**C1–C5 superados.** El consejo terminó en **CONSENSO en la ronda 4** sin ningún FAILED, 65,
75, `bloqueada`, `--manual`, recordatorio ni reintento, y con `anomalies: []`. La prueba sacó a
la luz **tres fricciones** que no invalidan el resultado pero conviene corregir (abajo), y una
de ellas obligó a reanudar al líder a mano una vez.

## Evidencia

### C1 — Desenlace y artefactos

- `council.sh status` → `PHASE: informe (escrito)`, `STATUS: CONSENSO`,
  `- ronda 4: A APPROVED · B APPROVED`, exit 0.
- El historial de veredictos: rondas 1–3 en SIN_CONSENSO, con desacuerdos reales.
  - **Ronda 1:** objeciones P2 nuevas de los dos.
  - **Ronda 2:** Astra aprueba y Fable reabre A-2.
  - **Ronda 3:** Fable aprueba y Astra reabre B-1, sobre el visto bueno legal previo.
  - **Ronda 4:** aprueban los dos.
- Artefactos presentes: el brief, las 3 propuestas, los 3 contrainterrogatorios, las síntesis
  v1–v4, las auditorías v1–v4, `registro.md`, `rondas/r1…r4-{A,B}.md`, los prompts de cada
  fase, `informe.md`, `metadatos.md` y `estrategia-final.md`, idéntico byte a byte a
  `sintesis-v4.md`.

### C2 — Modelos y esfuerzo

- **Astra:** 6 turnos sustantivos sobre un solo hilo (`-g1`). Los `t1…t6.meta.json` dicen todos
  `{"model":"gpt-6-astra","effort":"max","sandbox":"read-only"}` y cada turno tiene su recibo
  `t<N>.ok`. No hubo recordatorios, así que no hay ningún turno en `low`.
- **Fable:** 6 capturas, una por fase, todas `capturado` y `modelo: verificado` con
  `modelos: ["claude-fable-5-1"]`. Fue un único agente, continuado 5 veces por `SendMessage`
  y nunca reconstruido.
- **Líder:** se autodeclaró `claude-opus-5-5`, y el usuario confirmó Opus 5.5 · max en el gate
  del brief.

### C3 — Registro, estado y tokens

- `council.sh ledger` → `LEDGER: OK (33 objeciones, cada una en exactamente una fila)`. El
  estado coincide con la sección «Estado» del informe.
- Tokens, de `metadatos.md`:

  | Asiento | Entrada | Salida |
  | --- | --- | --- |
  | Astra | 6.564.133 (5.134.080 en caché) | 153.310 |
  | Fable | 7.235.333 leídos de caché | 27.055 (**cota inferior**: fricción 3) |
  | Líder | no medido | no medido |

### C4 — Nada fuera de su sitio

La carpeta estaba vacía al empezar (listado guardado antes del run). Al final hay 120 entradas,
todas bajo `docs/council/<run-id>/` y `.tandem/`, salvo `.claude/settings.local.json`. Ese
fichero lo crea la app al abrir la sesión (permisos), no el consejo. No se tocó nada fuera de la
carpeta ni en el repo del plugin.

### C5 — Formas reales frente a fixtures

- **Respuesta de Fable:** llegó **siempre** como `tool_use` `SubagentHandback` con
  `input.message`, tanto al lanzarlo como en las 5 continuaciones por `SendMessage`. Valida
  la forma de `synthetic-continuation.jsonl`. La rama de bloques `text` no se ejercitó: sigue
  sin validar, pero es solo un respaldo.
- **Cursor de `capture`:** leyó solo las líneas nuevas, en tramos contiguos (1–110, 111–143,
  144–187, 188–207, 208–232 y 233–256 de un transcript de 256 líneas). Lo publicado es idéntico
  byte a byte a lo capturado.

### Tiempo

- **Efectivo:** unos 73 minutos de consejo, de los que Fable fueron unos 36 y Astra unos 19.
- **Reloj:** casi 22 horas en total, por dos esperas.
  - 4 h 27 min esperando la idea del usuario;
  - 15 h 5 min parado por la fricción 1, hasta que la sesión de origen reanudó al líder.

## Fricciones encontradas (para corregir)

1. **El líder se queda parado esperando la notificación de fin de Fable.** Severidad alta para
   el uso real: sin ayuda externa, el consejo se cuelga.
   - **Qué pasa:** la skill declara barreras duras la notificación de la Bash de Astra y la de
     fin del agente Fable. En la app de escritorio esta última llega DESPUÉS del
     `SubagentHandback` y no abre turno («0 turns»), así que el líder que espera por ella no
     vuelve a despertar.
   - **Cómo se resolvió en el canario:** con la regla «el `SubagentHandback` es la barrera de
     Fable», sin más problemas.
   - **Arreglo:** cambiar la frase de la barrera en `skills/council/SKILL.md` y su ancla en
     `tests/skill-council-contract.test.sh`.
2. **`council.sh` resuelve el proyecto con `$PWD` cuando `CLAUDE_PROJECT_DIR` no está
   definido**, y el directorio de trabajo del líder cambió varias veces durante el run. El
   líder tuvo que hacer `cd` explícito en cada llamada.
   - **Arreglo:** que la skill fije la raíz del proyecto en el paso 0 y la pase en cada
     comando (`CLAUDE_PROJECT_DIR="<raíz>" bash "$COUNCIL" …`), como ya hace la review de
     rangos.
3. **Los tokens de salida de Fable salen por debajo de los reales.** En el transcript, el
   mensaje del `SubagentHandback` nunca recibe su `usage` definitivo.
   - **Medido:** los 6 mensajes de entrega (de 4 a 27 KB de texto) registran 3–4
     `output_tokens` en todas sus líneas, con `stop_reason: null`.
   - **Consecuencia:** la regla «última línea por `message.id`» es correcta, pero la fuente
     está incompleta, y los 27.055 de `metadatos.md` son una cota inferior.
   - **Arreglo:** marcarlo en `metadatos.md` como cota inferior cuando el mensaje final no
     tenga `stop_reason`, y valorar como fuente complementaria el `subagent_tokens` de la
     notificación del harness.

**Corregidas en v0.36.1** (code review de Astra en `docs/reviews/council.md`):
1. La skill declara barreras la notificación de la Bash de Astra y el `SubagentHandback` de
   Fable, y prohíbe esperar además la notificación de fin del agente.
2. `init` imprime y registra `PROJECT`, todas las llamadas posteriores de la skill lo fijan y
   `council.sh` busca el run en los padres del directorio de trabajo.
3. `capture` cuenta los mensajes sin `usage` definitivo y `metadatos.md` declara la cota
   inferior. Los metadatos de ESTE canario se generaron con v0.36.0 y no la declaran: sus
   27.055 tokens de salida de Fable se leen como «≥ 27.055».

Otras observaciones, sin acción necesaria:
- La ambigüedad del brief sobre la restricción legal provocó casi todo el debate. Es lo que el
  consejo debe hacer.
- Los P3 de la última ronda solo pueden quedar ABIERTA, porque la síntesis ya no cambia. El
  informe los lista como decisiones pendientes.
- Dos fuentes no fueron accesibles (403 y error de la web del club) y la auditoría las marcó
  como tales. La fecha se rehízo con otras fuentes.
