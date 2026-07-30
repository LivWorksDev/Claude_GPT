# Plan: statusline-opus — línea 2 visible durante implementaciones Opus

**Backlog:** M12 (P2/S) · **Fecha:** 2026-07-31 · **Modo:** autónomo (cola `.tandem/autonomous/queue.md`, tarea 3/6)

## Goal

La línea 2 de la statusline queda muda durante las implementaciones Opus (limitación v1
documentada): solo lee el heartbeat Codex. Pero
`.tandem/state/implement-claude/<slug>.json` ya contiene `status: running|terminal` y
`last_sentinel` — presencia y desenlace, el 80% del valor. Objetivo: fallback de línea 2
que, SOLO cuando no hay heartbeat Codex que renderizar, muestre
`⚒ opus implement · running · <slug>` (ámbar) durante el intento y el sentinel coloreado al
terminar. Sin actividad en vivo — eso sigue siendo v2 y prometerlo sería sobrevender.

## Approach

1. **`scripts/statusline.sh` — etapa de SELECCIÓN DE GANADOR, no un fallback tras los
   exits.** La estructura "fallback donde el camino Codex se rinde" no puede ejecutar la
   regla de prioridad: un heartbeat terminal reciente o un orphaned NO salen — se
   renderizan directamente. La línea 2 se reestructura en tres pasos: (1) parsear el
   heartbeat Codex y clasificarlo — `running` con pid vivo → renderizar Codex y terminar
   (cortocircuito, el camino actual intacto); `running` con pid 0 o no numérico es
   "desconocido pero NO orphaned" y CONSERVA la prioridad actual (el contrato existente de
   `statusline-orphaned-pid` renderiza Codex cuando la muerte no está establecida — solo un
   pid > 0 comprobadamente muerto degrada a orphaned); (2) localizar y parsear el candidato
   Opus — un JSON inválido/corrupto es "sin candidato Opus elegible", NUNCA un exit
   inmediato: con un heartbeat Codex no vivo elegible presente, ese se renderiza (un
   fichero histórico corrupto no puede hacer desaparecer un resultado Codex válido), y solo
   sin ningún candidato usable la línea 2 se ausenta; (3) entre el heartbeat NO vivo
   elegible (terminal en ventana u orphaned) y el candidato Opus elegible, seleccionar el
   ganador por timestamp y renderizar solo ese. El bloque Opus:
   - Localiza el `implement-claude/*.json` MÁS RECIENTE por mtime, con la misma resolución
     de raíz doble que el heartbeat (project dir del payload → checkout principal vía
     git-common-dir) — una sesión abierta dentro de un worktree ve el estado del principal.
   - Extrae `status`, `last_sentinel` y el slug (basename del fichero sin `.json` — los
     ficheros de attempt state usan el slug plano, sin hash) vía jq con el transporte
     `\x1f` y el mismo saneado que el heartbeat; un fallo de parseo elimina SOLO al
     candidato Opus de la selección (regla del paso 2 de arriba) — jamás un exit que
     suprima al heartbeat Codex elegible.
   - Renderiza: `status == "running"` → `⚒ opus implement · running · <slug>` en ámbar;
     `status == "terminal"` → icono/color por sentinel (`IMPLEMENTATION_COMPLETE` ✓ verde,
     `IMPLEMENTATION_PARTIAL` ↺ ámbar, sentinel ausente/otro · gris) + slug.
   - **Ventanas de visibilidad por mtime del JSON:** terminal → 900 s (la misma regla que
     el heartbeat Codex); running → hasta 2 h y después `⚠ opus implement · sin señal ·
     <slug>` en gris (el JSON se escribe al lanzar y al cerrar — un running de horas
     significa casi siempre sesión muerta sin cierre; un ⚠ honesto supera tanto el
     silencio como fingir actividad, mismo criterio que el estado `orphaned`). mtime
     portable con dos ramas (`stat -f %m` BSD → `stat -c %Y` GNU); si ambas fallan, se
     muestra sin ventana (degradación visible, nunca crash).
   - **Regla de prioridad: Codex VIVO gana siempre; entre estados no vivos, el más
     reciente.** Un heartbeat Codex `running` con pid vivo tiene prioridad absoluta. Pero
     un heartbeat TERMINAL reciente (ventana de 900 s) u ORPHANED no puede tapar un intento
     Opus más nuevo: en el ciclo de vida normal del pipeline, la plan-review Codex termina
     e inmediatamente arranca Opus — con prioridad absoluta del terminal, un intento Opus
     de < 15 min jamás mostraría `running`, y la review posterior pisaría el heartbeat
     antes de que el desenlace Opus se viera: la feature sería invisible exactamente cuando
     se necesita. Y un heartbeat orphaned (running + pid muerto, exento de la supresión por
     antigüedad) taparía todos los intentos Opus futuros para siempre. Comparación:
     mtime del JSON de implement vs `updated_at` del heartbeat — el más nuevo se renderiza.
   - **Empates y timestamps ausentes, deterministas:** ambos relojes tienen resolución de
     segundo y la transición normal del pipeline es inmediata, así que en EMPATE gana el
     candidato Opus `running` frente a un Codex no vivo (es el estado que acaba de nacer);
     un empate entre Opus terminal y Codex no vivo lo gana Codex (orden estable: en duda,
     el camino existente). Sin mtime del JSON (ambas ramas de `stat` fallidas): si existe un
     heartbeat Codex elegible, gana Codex (sin reloj no se desempata contra él); sin ningún
     heartbeat elegible, el candidato Opus se muestra sin ventana (la degradación visible
     ya definida). Ambos casos con test propio (el de `stat` forzado a fallar con el stub
     de `$SANDBOX/bin` descrito en Tests — nunca vaciando el PATH, que mataría a jq antes).
2. **`skills/implement/SKILL.md` — la nota v1 se actualiza.** El paso 3.4 deja de decir
   "second row is intentionally absent in v1": ahora la línea 2 muestra presencia y
   desenlace desde el JSON durable; la actividad en vivo sigue siendo v2 explícitamente.
3. **`README.md` — sección de statusline.** "Durante la implementación Opus esa segunda
   línea no aparece en v1" → describe el fallback (presencia/desenlace desde el attempt
   state; actividad en vivo v2).
4. **Tests.**
   - `tests/statusline-opus-fallback.test.sh` (nuevo, comportamental — ejecuta
     `statusline.sh` con payloads sintéticos como los tests de statusline existentes):
     sin heartbeat Codex + JSON running (mtime fresco) → línea con `⚒`, `opus implement`,
     `running` y el slug; JSON terminal + IMPLEMENTATION_COMPLETE → `✓` verde con slug;
     terminal + IMPLEMENTATION_PARTIAL → `↺`; terminal sin sentinel → `·` gris; terminal
     con mtime > 900 s → línea 2 ausente; running con mtime > 2 h → `⚠` y `sin señal`;
     heartbeat Codex `running` con pid vivo + JSON running → gana Codex (la línea lleva
     `codex`, no `opus implement`); **la transición real del pipeline**: heartbeat terminal
     de plan-review FRESCO (< 900 s) + JSON Opus running MÁS NUEVO → gana el fallback Opus;
     heartbeat terminal más nuevo que un JSON viejo → gana Codex; heartbeat orphaned viejo
     (running + pid muerto) + JSON Opus fresco → gana el fallback (el orphaned no puede
     tapar para siempre); heartbeat Codex terminal ya suprimido (>900 s) + JSON running
     fresco → fallback; varios JSON → el más reciente por mtime; **empate exacto de
     timestamps** (touch -t al mismo segundo que updated_at): Opus running gana al Codex no
     vivo, Opus terminal pierde; **stat inalcanzable** (sandbox sin el binario): con
     heartbeat elegible gana Codex, sin él Opus se muestra sin ventana; JSON corrupto →
     exit 0 sin stderr; resolución de raíz doble (payload en worktree, estado en el
     principal); **candidato Opus corrupto + heartbeat Codex terminal fresco → se renderiza
     Codex** (la corrupción no suprime al válido); **heartbeat running con pid 0 + candidato
     Opus fresco → gana Codex** (pid desconocido conserva el contrato existente). Los mtime
     se fabrican con `touch -t`, sin sleeps; el caso de `stat` inalcanzable se monta con un
     stub de `stat` QUE FALLA en `$SANDBOX/bin` (que precede a /usr/bin en el PATH del
     runner) — vaciar el PATH mataría antes a jq y el branch jamás se ejecutaría.
   - `tests/statusline-never-fail.test.sh` (ampliar): implement-claude JSON corrupto,
     vacío, ilegible y con status/sentinel no-string → exit 0, stderr vacío, **exactamente
     una línea de salida y sin rastro de `opus implement`** — el contrato es "línea 2
     ausente", no solo "sin crash": un placeholder renderizado por un parseo a medias
     pasaría una aserción de solo rc/stderr.
5. **Metadatos — orquestador tras la implementación:** `.claude-plugin/plugin.json` →
   `0.15.0`, `CHANGELOG.md`, `docs/BACKLOG.md` (M12 → `hecha (v0.15.0)`), fila de la cola.

## Key decisions & tradeoffs

- **Codex VIVO gana siempre; entre estados no vivos, el más reciente** (refina el
  pre-registro de la cola, que da prioridad al heartbeat "vivo" — no al terminal lingering):
  las fases Sol y Opus se alternan pegadas en el pipeline, así que un terminal reciente o
  un orphaned eterno taparían el fallback exactamente en su caso de uso; la comparación por
  timestamp resuelve ambos sin tocar el camino Codex-vivo.
- **Presencia y desenlace, no actividad** (pre-registrado): el JSON durable se escribe al
  lanzar y al cerrar; cualquier "actividad" intermedia sería inventada. El 80% del valor
  (¿sigue vivo? ¿cómo acabó?) con el 20% del coste.
- **`⚠ sin señal` a las 2 h en vez de running eterno o supresión:** un JSON running sin
  cierre es indistinguible de una sesión muerta; el gris honesto es el mismo criterio que
  el estado `orphaned` del heartbeat (mostrar incertidumbre, nunca fingir trabajo). El
  umbral de 2 h cubre holgadamente el intento Opus más largo observado (~25 min).
- **mtime con dos ramas de `stat`:** no hay forma POSIX pura de leer mtime en bash 3.2;
  BSD y GNU difieren y ambos userlands son objetivo declarado del proyecto. La degradación
  (sin mtime → mostrar sin ventana) es visible y segura.
- **El slug sale del filename:** el attempt state usa el slug plano (a diferencia del
  estado Codex, que usa `target_key` con checksum) — no hay hash que revertir.

## Files to touch

| Fichero | Naturaleza del cambio |
| --- | --- |
| `scripts/statusline.sh` | Bloque de fallback opus tras el camino Codex |
| `skills/implement/SKILL.md` | Nota v1 actualizada (presencia/desenlace sí; actividad v2) |
| `README.md` | Sección statusline: describe el fallback |
| `tests/statusline-opus-fallback.test.sh` | Nuevo, comportamental |
| `tests/statusline-never-fail.test.sh` | Ampliar: JSONs de implement corruptos |
| `.claude-plugin/plugin.json` · `CHANGELOG.md` · `docs/BACKLOG.md` | v0.15.0 (orquestador) |

## Acceptance & proof

- Durante una implementación Opus (JSON running, sin heartbeat Codex) la línea 2 muestra
  `⚒ opus implement · running · <slug>` en ámbar; al terminar, el sentinel coloreado
  durante 900 s; un running de > 2 h degrada a `⚠ sin señal` gris.
- Un heartbeat Codex `running` con pid vivo gana SIEMPRE; un terminal fresco cede ante un
  intento Opus más nuevo (la transición real del pipeline) y lo tapa cuando es él el más
  nuevo; un orphaned viejo cede ante un intento Opus fresco; uno ya suprimido cede siempre.
- JSON corrupto/ilegible/ausente → el candidato Opus desaparece de la selección: con un
  heartbeat Codex elegible presente se renderiza ese; SOLO sin ningún candidato usable la
  línea 2 está ausente (exactamente una línea de salida, sin `opus implement`), exit 0,
  stderr vacío (nunca ruido en la UI).
- La resolución de raíz doble funciona desde un worktree.
- Las notas "absent in v1" de skill y README quedan sustituidas por la descripción real.

**PROOF:** `bash tests/verify.sh` (suite completa + shellcheck + actionlint pineados).

## Risks

- **Interferencia con el heartbeat Codex:** el cortocircuito de Codex-vivo preserva el
  camino actual byte a byte; la selección de ganador solo toca estados no vivos, y los
  cinco tests de prioridad (vivo, transición real, terminal más nuevo, orphaned viejo,
  suprimido) fijan cada arista.
- **Portabilidad de `stat`:** dos ramas + degradación; shellcheck pineado y CI en ambos
  userlands.
- **JSONs de otros slugs antiguos:** la ventana por mtime los suprime; el "más reciente"
  evita ambigüedad con varios intentos históricos.

## Out of scope

- Actividad en vivo del subagente Opus (v2 explícito).
- Cambios en cómo Fable escribe el attempt state (el formato actual ya basta).
- Tokens en el fallback (el attempt state no los tiene; M9 cubre los turnos Codex).
- El resto de la cola (M5, M7, M10).

## Assumptions

Modo autónomo: decisiones que habría consultado, con su default.

1. **¿Cuándo se muestra el fallback?** → El pre-registro de la cola dice "solo sin
   heartbeat Codex VIVO"; la revisión del plan lo precisó: Codex running con pid vivo tiene
   prioridad absoluta, y entre estados no vivos gana el más reciente con empates
   deterministas — la lectura literal "cualquier heartbeat renderizable gana" haría la
   feature invisible en el ciclo de vida normal del pipeline.
2. **¿Qué muestra?** → Presencia y desenlace (pre-registrado); nada de actividad inventada.
3. **¿Staleness de un running sin cierre?** → `⚠ sin señal` gris a las 2 h (criterio
   `orphaned`); terminal 900 s como el heartbeat. No pre-registrado: default conservador
   elegido — ni supresión silenciosa ni running eterno.
4. **¿mtime portable?** → `stat -f %m` → `stat -c %Y` → sin ventana (degradación visible).
5. **¿Rama?** → `tandem/statusline-opus` apilada sobre `tandem/token-accounting` (cadena de
   la cola), aprobada con `plan-approve.sh`.
6. **¿Versión?** → 0.15.0; metadatos del orquestador tras la implementación.
