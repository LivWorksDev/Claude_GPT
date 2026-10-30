# Review — council-effort-profiles (v0.38.0)

- **Fecha:** 2026-10-30
- **Plan:** `docs/plans/council-effort-profiles.plan.md`. Hay tres perfiles de esfuerzo para
  `/tandem:council`: exploratorio (high), estándar (xhigh) y crítico (max). Cada perfil fija
  un solo nivel para el líder, Fable y Astra. La skill lo recomienda, el usuario lo elige en el
  gate del brief y queda congelado con el brief. Nace de una petición del mantenedor: elegir el
  esfuerzo con human in the loop, con Fable y Astra siempre al mismo nivel.
- **Rama:** `tandem/council-effort-profiles`, sobre `main` en b25ee96 (v0.37.0). El plan está
  commiteado en d38cffb.
- **Gate:**
  - lint: OK (shellcheck 0.10.0 en `scripts/` y `tests/`; actionlint 1.7.7);
  - typecheck: n/a (bash);
  - tests: 104 passed, 0 failed (casos A1–A8 dentro de los tests del consejo, más una
    regresión de la code review);
  - proof (`TESTS_BASH=/bin/bash bash tests/verify.sh`): OK, repetido después de cada arreglo.
- **Plan review (Astra, xhigh, hilo persistente):** 2 rondas → `VERDICT: APPROVED`.
- **Code review (Astra, xhigh, hilo fresco):** 2 rondas → `VERDICT: APPROVED`.
- **Implementación:** Opus 5.5 (`tandem:implementer`, transporte opus), en un intento y sin
  continuaciones. El plan se le pasó por ruta + blob hash. El orquestador escribió la versión,
  el CHANGELOG, la línea del consejo del doctor y un comentario desfasado de `_common.sh`.
- **Tokens Codex:**
  - plan: in 4.178.721 / out 14.801;
  - code review: in 4.138.453 / out 20.486.

## Evidencia previa a la implementación

Antes de dar por buena la comprobación de esfuerzo en `capture`, que termina en un 65, se hizo
un diagnóstico con niveles distintos (Claude Code 2.1.312):

- la sesión padre corría en `medium`;
- se lanzó `tandem:implementer-critical`, con `effort: xhigh` en su frontmatter;
- se continuó por `SendMessage`.

Todas las líneas del subagente registraron `effort=xhigh`, `perTurnEffort=xhigh` y
`attributionAgent=tandem:implementer-critical`, tanto en el lanzamiento como en la
continuación. Es decir, el campo refleja el frontmatter del subagente y no la sesión. Ese
transcript, saneado, es el fixture `tests/fixtures/council/subagent-transcript-effort.jsonl`.

## Hallazgos y disposiciones (condensado)

### Plan review — 2 rondas, 3 hallazgos P2, todos ACEPTADOS

- **R1 `REVISE`:**
  - **(P2) Recuperar con un perfil congelado inviable.** Ejemplo: un run `estandar` recuperado
    con `CLAUDE_CODE_EFFORT_LEVEL=high` pasaba el preflight y acababa en un 65 después de gastar
    turnos. Arreglo: `profile_env_check` en `stage` y `astra`, antes de reservar nada (exit 1,
    `run.json` intacto), y `PERFIL_VIABLE:` en `status`.
  - **(P2) Medición del líder sin ventana superior, y Markdown y HTML en desacuerdo.** Arreglo:
    - dos ventanas cerradas por marcas de `run.json`: entrevista (informativa) y debate (hasta
      el `publish` de la última ronda completa);
    - una instantánea `lider-esfuerzo.json` que `report` solo lee y que entra en la huella de
      frescura.
  - **(P2) El canario no distinguía el esfuerzo del subagente del de la sesión, y el saneador
    borraba los campos.** Arreglo:
    - el diagnóstico de arriba, ya hecho;
    - `sanitize.jq` conserva los tres campos;
    - el canario A9 corre con el líder a propósito en max y un perfil `exploratorio`.
- **R2 `APPROVED`:** los tres resueltos y ningún hallazgo nuevo.

### Code review — 2 rondas, 2 hallazgos Minor, ambos ACEPTADOS

- **R1 `REQUEST_CHANGES`:**
  - **(Minor) Ventana del líder inestable.** Las fracciones de segundo se truncaban en el
    corte, y se deduplicaba antes de filtrar por tiempo: una línea en 12:00:00.900Z, o una
    línea posterior de un `message.id` ya contado, cambiaban un recuento cerrado. Arreglo:
    - `ep` conserva la fracción;
    - la ventana se aplica antes de deduplicar;
    - test de regresión, comprobado: falla con el código anterior y pasa con el arreglo.
  - **(Minor)** La sección «Coste» del README seguía diciendo que cada turno es max.
    Arreglo: ahora habla del nivel del perfil.
- **R2 `APPROVED`:** sin hallazgos nuevos.

## Desviaciones del implementador aceptadas

- El preflight no aplica la regla «definida y vacía = 64» a `TANDEM_COUNCIL_EFFORT` ni a
  `TANDEM_COUNCIL_PROFILE`, para poder informar de ellas como FAIL junto al resto de problemas.
- Los fixtures de transcript anteriores pierden las tres claves que el saneador antiguo había
  convertido en `"<x>"` (de otro modo se leerían como desajuste). Ahora cubren el caso «no
  verificado».
- El perfil va en `data.run.perfil` del payload del informe.

## Pendiente

- **A9:** canario real manual tras el merge. Un consejo `exploratorio` de una ronda, con el
  líder en max, en una sesión nueva (para que se registren los cuatro agentes nuevos). Si Fable
  registrara el esfuerzo de la sesión, la comprobación de `capture` se degrada a anomalía antes
  de etiquetar la versión.
