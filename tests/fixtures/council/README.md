# Fixtures de `council.sh capture`

Este directorio alimenta `tests/council-capture.test.sh` (y los casos de `capture` de
`tests/council-run.test.sh` y `tests/council-lifecycle.test.sh`). Hay dos clases de fichero, y la diferencia importa: la
fixture derivada de un transcript REAL valida la conversión contra la forma que Claude Code
escribe de verdad; las variantes SINTÉTICAS solo cubren ramas que la captura real no
ejercitó, y las valida el canario real del plan (C5) — lección de M20a: un test construido
con la forma de salida supuesta valida la suposición, no la conversión.

| Fichero | Clase |
| --- | --- |
| `subagent-transcript.jsonl` | derivado de un transcript REAL (abajo) |
| `subagent-transcript-streaming.jsonl` | derivado de un SEGUNDO transcript REAL, con `usage` de streaming (abajo) |
| `subagent-transcript-effort.jsonl` | derivado de un TERCER transcript REAL: un subagente a `xhigh` bajo una sesión a `medium`, lanzamiento y continuación (abajo) |
| `expected-reply.txt` | el `input.message` exacto del `SubagentHandback` de esa fixture |
| `sanitize.jq` | el saneado que se le aplicó |
| `synthetic-continuation.jsonl` + `synthetic-continuation-reply.txt` | SINTÉTICO — segundo turno añadido (continuación por `SendMessage`) |
| `synthetic-text-reply.jsonl` + `synthetic-text-reply-expected.txt` | SINTÉTICO — respuesta final en bloques `text`, sin `SubagentHandback` |

## Derivación de `subagent-transcript.jsonl`

- **Fuente:** transcript REAL de un subagente (`claude-code-guide`) de Claude Code 2.1.302
  (app de escritorio, macOS), grabado el 2026-10-18. Es el fichero al que apunta el
  `output_file` que el harness devuelve al lanzar un Agent en background (symlink a
  `~/.claude/projects/<proyecto>/<sesión>/subagents/agent-<id>.jsonl`).
- **Forma real observada:** 229 líneas: 103 `assistant`, 60 `user`, 66 `attachment`. Las 103
  líneas `assistant` tienen solo 57 `message.id` distintos: cada mensaje de la API se reparte
  en varias líneas (claves de `message.usage`: `input_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens`, `output_tokens`, más metadatos). En esta captura corta todas
  las líneas de un mensaje traen el mismo `usage`; en mensajes largos NO (ver la fixture de
  streaming): solo la ÚLTIMA línea de cada `message.id` lleva el `usage` definitivo, y
  `council.sh capture` se queda con esa.
  Ningún mensaje `assistant` tiene bloques `text`: la respuesta final llega como un `tool_use`
  llamado `SubagentHandback` con `input: {"message": "<respuesta>"}`. El modelo real de todas
  las líneas `assistant` era `claude-haiku-5-5`.
- **Saneado (`sanitize.jq`, aplicado línea a línea con `jq -c --rawfile payload
  expected-reply.txt`):** todo valor string cuya clave no esté en la lista de estructura
  (`type`, `name`, `id`, `model`, `role`, `tool_use_id`, `stop_reason`, `stop_sequence`,
  `timestamp`, `version`, `entrypoint`, `service_tier`, `speed`, `inference_geo`, `userType`,
  `permissionDecision`; y, desde los perfiles de esfuerzo, `effort`, `perTurnEffort` y
  `attributionAgent`) se sustituye por `"<x>"` — textos, thinking, inputs de herramientas,
  rutas, cwd, rama, ids de sesión y de agente. Números y booleanos (el `usage` entre ellos) se
  conservan tal cual. El `input.message` del `SubagentHandback` se sustituye por el contenido
  de `expected-reply.txt` (multilínea, con comillas, acentos y backticks) para poder comprobar
  la extracción byte a byte. Después, `message.model` de toda línea `assistant` pasa a
  `claude-fable-5-1`.
- **Recorte:** para no pasar de lo que pesan las demás fixtures del repo (4–40 KB), se
  conservan las líneas 1–27 y 219–229 del transcript saneado (38 líneas): los cuatro primeros
  grupos de `message.id` y los tres últimos, completos (ningún grupo partido), con las líneas
  `user`/`attachment` intercaladas y el `SubagentHandback` final. La repetición de `usage`
  por grupo se mantiene, así que la suma ingenua por línea difiere de la deduplicada
  (`output_tokens`: 94 por línea frente a 56 por `message.id`).
- **Privacidad:** comprobado que la fixture no contiene `/Users/`, el nombre de usuario, el
  correo, el nombre del proyecto local ni los ids de la sesión de origen.

Comando de derivación (desde el transcript real, fuera del repo):

```sh
jq -c --rawfile payload expected-reply.txt -f sanitize.jq agent-<id>.jsonl \
  | jq -c 'if .type == "assistant" then .message.model = "claude-fable-5-1" else . end' \
  > saneado.jsonl
sed -n '1,27p;219,229p' saneado.jsonl > subagent-transcript.jsonl
```

El caso de modelo ajeno lo genera el test devolviendo `message.model` a su valor real,
`claude-haiku-5-5` (en todas las líneas o en una sola).

## Derivación de `subagent-transcript-streaming.jsonl`

- **Por qué existe:** la primera fixture no distingue la primera línea de un mensaje de la
  última (en ella su `usage` coincide), así que no detectaría una deduplicación que se quedase
  con la primera. Verificando la implementación (2026-10-18) el orquestador midió un segundo
  transcript real y largo: el del propio subagente implementador de esta feature (Claude Code
  2.1.302 desktop; 1480 líneas, 666 `assistant` sobre 304 `message.id`, todas de
  `claude-opus-5-5`). En 47 de esos mensajes el `usage` CRECE de línea en línea — las primeras
  llevan los recuentos parciales del streaming y la última el definitivo —: quedarse con la
  primera línea daba 6.514 tokens de salida, con la última 152.578 (el valor real) y la suma
  ingenua por línea 155.542.
- **Recorte:** líneas 1–14, 40–56 y 1476–1480 del transcript (36 líneas): cuatro mensajes
  completos cuyo `output_tokens` crece — [8,8,8,330], [16,16,16,341], [16,16,260] y el
  mensaje final [8,8,4217], que trae thinking, un bloque `text` y el `SubagentHandback` (otra
  forma real: el mensaje de entrega puede llevar también texto) — con las líneas
  `user`/`attachment` intercaladas.
- **Saneado:** el mismo `sanitize.jq` con el mismo `expected-reply.txt` como `input.message`, y
  `message.model` (real: `claude-opus-5-5`) a `claude-fable-5-1`. Barrido de privacidad
  limpio.
- **Lo que fija el test:** última línea por mensaje → `output_tokens` 5148 (y
  `input_tokens` 8, `cache_read_input_tokens` 886207, `cache_creation_input_tokens` 34997);
  primera línea → 48; suma ingenua → 5268.

```sh
sed -n '1,14p;40,56p;1476,1480p' agent-<id>.jsonl \
  | jq -c --rawfile payload expected-reply.txt -f sanitize.jq \
  | jq -c 'if .type == "assistant" then .message.model = "claude-fable-5-1" else . end' \
  > subagent-transcript-streaming.jsonl
```

## `effort`, `perTurnEffort` y `attributionAgent` en las fixtures anteriores

Las dos fixtures reales anteriores y las dos sintéticas se derivaron con el saneado ANTIGUO,
que no conocía esas tres claves y las convirtió en `"<x>"`: su valor real se perdió. Con los
perfiles de esfuerzo, `council.sh capture` compara `effort` y `attributionAgent` con el perfil
del run, y un `"<x>"` sería un desajuste falso. Se han ELIMINADO esas tres claves de las líneas
`assistant` de las cuatro (nada más cambia, comprobado byte a byte):

```sh
jq -c 'if .effort == "<x>" then del(.effort) else . end
  | if .perTurnEffort == "<x>" then del(.perTurnEffort) else . end
  | if .attributionAgent == "<x>" then del(.attributionAgent) else . end' <fixture>
```

Así ejercitan la rama de la AUSENCIA: la captura procede y queda marcada «no verificado»
(con su anomalía en `metadatos.md`). La rama verificada la cubre la fixture siguiente.

## Derivación de `subagent-transcript-effort.jsonl`

- **Por qué existe:** `capture` verifica el esfuerzo y el tipo de agente de Fable con dos
  campos no documentados de cada línea `assistant` (`effort`, `attributionAgent`). Hacía
  falta medir que reflejan el frontmatter del SUBAGENTE y no el de la sesión, también en una
  continuación por `SendMessage`.
- **Fuente:** el diagnóstico del plan de los perfiles (2026-10-30, Claude Code 2.1.312): un
  subagente `tandem:implementer-critical` (frontmatter `effort: xhigh`) lanzado en background
  desde una sesión a `medium`, y continuado después con `SendMessage`. 21 líneas: 1–17 el
  lanzamiento (un mensaje `msg_011CgYCkXJ6TQszegjg3JReL` repartido en dos líneas `assistant`,
  thinking + `text`), 18–21 la continuación (un mensaje `msg_011CgYCmLCsjo1miCnDSrgfV`, una
  línea `text`); además, líneas `attachment`, `api-request*` y `user`. Las tres líneas
  `assistant` llevan `effort: "xhigh"`, `perTurnEffort: "xhigh"` y `attributionAgent:
  "tandem:implementer-critical"`, aunque la sesión corría a `medium`; las líneas
  `api-request` traen `params.output_config.effort: "xhigh"`. El modelo real era
  `claude-opus-5-5`. La respuesta llega en bloques `text`, sin `SubagentHandback`.
- **Saneado:** el `sanitize.jq` de hoy (conserva `effort`, `perTurnEffort` y
  `attributionAgent`; `expected-reply.txt` como `$payload`, que no se usa: no hay
  `SubagentHandback`). Después, en cada línea `assistant`: `message.model` (real:
  `claude-opus-5-5`) pasa a `claude-fable-5-1`, `attributionAgent` (real:
  `tandem:implementer-critical`) pasa a `tandem:council-fable-xhigh` — el agente del perfil
  `estandar` —, y el texto de cada mensaje se sustituye por una respuesta conocida para
  comprobar la extracción. `effort` y `perTurnEffort` conservan su valor REAL, `xhigh`. Sin
  recorte. Barrido de privacidad limpio (ni `/Users/`, ni el usuario, ni el correo, ni el
  proyecto, ni los ids de sesión y de agente de origen).
- **Lo que fija el test:** en un run `estandar`, la captura del lanzamiento (líneas 1–17) y la
  de la continuación (18–21) verifican `xhigh` y `tandem:council-fable-xhigh`; con `effort`
  `max`, con el agente `tandem:council-fable`, con el agente real del diagnóstico o en un run
  `critico` → 65 y nada capturado.

```sh
jq -c --rawfile payload expected-reply.txt -f sanitize.jq agent-<id>.jsonl \
  | jq -c 'if .type == "assistant" then .message.model = "claude-fable-5-1"
      | .attributionAgent = "tandem:council-fable-xhigh"
      | .message.id as $id | .message.content |= map(if .type == "text" then .text =
          (if $id == "msg_011CgYCkXJ6TQszegjg3JReL" then "Respuesta del lanzamiento (diagnóstico saneado)"
           else "Respuesta de la continuación (diagnóstico saneado)" end) else . end)
    else . end' > subagent-transcript-effort.jsonl
```

## Variantes SINTÉTICAS

Las dos se generaron con `jq` a partir de líneas REALES de `subagent-transcript.jsonl`, para
conservar sus claves y tipos (línea 1 como plantilla `user`, 36 como `assistant` con
`thinking`, 37 como `assistant` con `SubagentHandback`, 38 como `user` con `tool_result`);
solo cambian `message.id`, `message.usage`, el contenido de los bloques y los timestamps.
Ningún dato procede de una sesión real: lo que prueban es una SUPOSICIÓN sobre la forma, y el
canario real del plan la confirma o la corrige.

- `synthetic-continuation.jsonl` — el segundo turno del mismo agente que el harness añadiría
  al MISMO fichero tras un `SendMessage`: una línea `user`, un mensaje `msg_SYNTHETIC_cont_0001`
  repartido en dos líneas `assistant` (thinking + `SubagentHandback`) con el mismo `usage`
  (`output_tokens` 11) y su `tool_result`. El test lo concatena tras la fixture real para
  comprobar que la segunda captura lee SOLO las líneas nuevas. Su `input.message` es
  `synthetic-continuation-reply.txt`.
- `synthetic-text-reply.jsonl` — una respuesta que termina en bloques `text` sin ningún
  `SubagentHandback`: un primer mensaje con `text` + `tool_use` (no cuenta: lleva una
  herramienta) y un último mensaje `msg_SYNTHETIC_text_0002` con thinking y dos bloques
  `text`, cuya concatenación es `synthetic-text-reply-expected.txt`.
