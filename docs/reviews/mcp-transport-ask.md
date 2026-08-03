# Review: mcp-transport-ask (v0.27.0)

- **Fecha:** 2026-08-03
- **Plan:** docs/plans/mcp-transport-ask.plan.md (M20a; primer salto de la Fase 2 —
  núcleo cliente MCP + rol `ask`)
- **Rama:** tandem/mcp-transport-ask desde main 7269c8b (el commit con los fixtures
  reales). Aprobación vía `plan-approve.sh` (commit del plan 2759019).
- **Gate:** lint: OK · typecheck: n/a (bash) · tests: 81 passed, 0 failed (2 ficheros
  nuevos) · proof: OK (`bash tests/verify.sh` → VERIFY OK, re-run tras cada fix)
- **Modo:** autónomo con DOS intervenciones humanas explícitas (un deadlock de plan y uno
  de code review, ambos autorizados a continuar); implementador: Claude Opus 5,
  IMPLEMENTATION_COMPLETE en t1; fixes de review del orquestador.
- **Tokens del run:** plan-review 6 rondas — in 31 282 171 · out 205 753; code review 6
  rondas — in 52 913 849 · out 227 520; implementación: n/a (transporte opus).

## Plan review — 6 rondas → APPROVED (8 → 5 → 1 → 2 → 1 → 0), con DEADLOCK resuelto

16 hallazgos. El primero fue el más caro: mi "desenvoltura" de eventos era **ficción** —
el stream MCP real lleva `params={_meta,id,msg}` con tipos propios, y la evidencia estaba
en nuestro propio archivo de M19. También: `hb_begin` REEMPLAZA el trap EXIT (los traps
no se apilan) → un solo owner del ciclo de vida; un `mv` de TMPDIR al home NO es rename
atómico; la credencial quedaba retenida en el camino de fallo; el writer TOML era
inyectable con modelos hostiles; el watchdog era más largo que el timeout de quien lo
llama; y el veredicto estático no estaba atado a la versión auditada. La ronda 5 agotó el
cap por un P2 de puntería de fichero; el humano autorizó la 6 → APPROVED.

## Code review — 6 rondas → APPROVED (7 → 3 → 1 → 1 → 1 → 0), con DEADLOCK resuelto

21 hallazgos en total entre ambas fases. **La misma clase de defecto se repitió cinco
veces:** el adaptador convertía desde la forma que el orquestador SUPONÍA, no desde la
que el protocolo emite — y los tests que escribía alimentaban esa suposición, así que
pasaban en verde confirmando el error. Víctimas concretas: el argv de un comando
serializado como el texto `["ls","-l"]`; el razonamiento leyendo `summary` cuando el core
usa `summary_text`; el mapa de `changes` descartado por un test de array; y
`CollabAgentToolCall` perdiendo el discriminador de exec, el `tool` (con su traducción
`resume_agent`→`wait`) y la identidad de qué agentes colaboran. Además: seguridad — un
`TMPDIR` apuntando a `.tandem/tmp` habría puesto la credencial ahí (ahora se canonicaliza
y se rechaza, con prueba CONDUCTUAL); el watchdog daba el timeout completo a tres esperas
sucesivas (ahora un deadline absoluto único); el error del adaptador no se propagaba
(seguía narrando, reubicando y BORRANDO el rollout origen); y un `chmod` fallido en el
staging destruía el único rollout recuperable — agujero abierto por mi propio fix de
seguridad de la ronda anterior.

## Bug de jq encontrado por el orquestador al verificar

`($i.exit_code | numbers) != null` produce **vacío** cuando el campo no es numérico; una
condición vacía anula el `if` entero; y en un `reduce` un cuerpo sin salida deja el
acumulador en `null`, **borrando en silencio todo lo acumulado**. Eso hacía desaparecer
`thread.started` y `turn.started` contra el stub (no contra el fixture real, cuyos items
traían todos los campos). Cinco condiciones corregidas, con ancla sobre el ORDEN del
stream adaptado y un caso de item sin campos opcionales. La aserción de conservación de
frames destapó de paso que un `item_started` suprimido no aparecía en NINGUNO de los dos
ficheros.

## Límite declarado, no disimulado

No se porta literalmente la máquina de correlación de IDs del procesador oficial de exec:
sin frames MCP reales de esas variantes, portarla sería inventar. Lo que se emite es
cierto; el límite queda anotado para M20b/M20c.
