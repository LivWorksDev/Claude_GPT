# Plan: implementador seleccionable — Opus 5 por defecto, Sol opcional

## Goal

Hacer seleccionable el implementador del pipeline tandem mediante la variable `TANDEM_IMPLEMENTER`, con **Claude Opus 5 (subagente Claude Code) como nuevo default** y Sol (Codex CLI, transporte actual) como alternativa (`TANDEM_IMPLEMENTER=sol`). Motivación: eliminar la correlación de puntos ciegos que existe hoy — Sol implementa (hilo B) y Sol revisa (hilo C); un punto ciego del modelo sobrevive al hilo fresco. Con Opus implementando y Sol revisando, generador y revisor adversarial son de familias distintas en cada gate. Los revisores no cambian: Sol sigue siendo el red-team del plan y el revisor final independiente.

## Approach

El cambio es de **transporte del rol implementador**, no de scripts: cuando `TANDEM_IMPLEMENTER` es `opus` (o no está definida), `tandem:implement` delega en un subagente Claude restringido en lugar de `codex-start.sh implement`; cuando es `sol`, el flujo Codex actual se ejecuta sin ningún cambio. Los gates (plan aprobado, clean tree, rama `tandem/<slug>`), la verificación personal de Fable, el testing gate bloqueante y el handoff a `tandem:review` son idénticos en ambos transportes.

Mecánica del transporte Claude (nueva sección en `skills/implement/SKILL.md`):

1. **Selector** — leer `TANDEM_IMPLEMENTER` (default `opus`). Valores válidos: `opus`, `sol`. Cualquier otro valor → parada dura con mensaje (fail-closed, sin fallback silencioso).
2. **Agent type restringido** — el plugin incluye `agents/implementer.md`: definición de subagente con allowlist de herramientas de mínimo privilegio (`Read, Edit, Write, Glob, Grep, Bash` — sin MCP, sin WebFetch/WebSearch, sin Agent anidado), `model: opus` en el frontmatter, y un system prompt que fija las prohibiciones (nunca `git commit`/`git push`/tocar ramas o remotos; ceñirse al plan; desviaciones → reportarlas, no improvisarlas). El allowlist es una frontera *aplicada por el harness* para herramientas y conectores; la amplitud de Bash queda como riesgo residual documentado (ver Risks) — equivalencia total con el sandbox OS de Codex no existe en v1.
3. **Preflight de modelo (fail-closed)** — antes de lanzar: si `CLAUDE_CODE_SUBAGENT_MODEL` está definida con un valor distinto de opus, parar con error (su precedencia pisaría el `model` del agent type). El informe del subagente incluye el modelo con el que cree correr (auto-atestación informativa); la verificación robusta en runtime no es posible desde dentro y se documenta como limitación.
4. **Lanzamiento** — nuevo template `skills/implement/prompts/implement-claude.tpl` con placeholders estilo `{{TARGET}}`/`{{EXTRA}}`; Fable lo rellena leyéndolo (no pasa por `load_prompt`, que es infraestructura bash de los scripts Codex). El prompt embebe: el plan completo, la ruta de trabajo, el mandato de escribir los tests que el plan especifica, y el contrato de salida: informe final (qué se hizo, qué falta, desviaciones, modelo auto-reportado) terminado en el sentinel `IMPLEMENTATION_COMPLETE` o `IMPLEMENTATION_PARTIAL`. Subagente en background para features reales, igual que hoy con Codex.
5. **Worktree explícito** — con `TANDEM_WORKTREE=1`, el subagente NO hereda el cwd correcto por sí solo: el prompt fija la ruta absoluta del worktree (`.worktrees/<slug>`) como única zona de trabajo, y la verificación de Fable y el testing gate corren con ese cwd — la misma regla que hoy, hecha explícita para el transporte claude.
6. **Estado durable** — `.tandem/state/implement-claude/<slug>.json`, escrito por Fable tras CADA lanzamiento y continuación: nombre/id del subagente, rondas de continuación consumidas, último sentinel, ruta del último informe (guardado en `.tandem/state/implement-claude/<slug>.t<N>.report.md`), ruta del worktree si aplica, y la **identidad del intento**: `plan_path`, `plan_hash` y `branch`. Es el espejo del estado de hilos Codex: el cap de rondas y el último PARTIAL sobreviven a compactaciones y sesiones nuevas.
   - **`plan_hash` = blob commiteado, no working copy**: `git rev-parse HEAD:docs/plans/<slug>.plan.md`. El plan aprobado se commiteó en el gate de tandem:plan y no recibe commits durante la implementación, así que ese blob es estable; la working copy NO sirve como identidad porque el implementador marca checkboxes del plan mientras trabaja (contrato existente de implement.tpl) y cada check cambiaría el hash, invalidando continuaciones legítimas.
   - **Ramas del protocolo de reutilización** (sin ambigüedad): identidad coincidente (`plan_hash` + `branch`) → reanudar el intento, o reset deliberado si el usuario quiere empezar de cero. Identidad NO coincidente → el estado es de otro intento y **solo** admite dos salidas: descartar (reset) o parar; reanudarlo no es una opción. **Reset exacto**: `rm` de `<slug>.json` y de los `<slug>.t*.report.md` de ese slug.
   - **Guard de liveness antes de cualquier reset — observacional, nunca mutante**: el estado del subagente registrado se consulta SOLO por vías que no lo alteran — `TaskList`/`TaskGet` sobre su id, o el estado terminal ya persistido en el json (sentinel del último turno). `SendMessage` está prohibido como sonda: enviar a un subagente completado lo reanuda en background (conducta documentada del harness), es decir, la sonda dispararía trabajo nuevo. Inactivo = no aparece en la sesión actual o su task está en estado terminal (los subagentes no sobreviven a la sesión que los creó). Además, si el estado registra un worktree, `git -C <worktree> status --porcelain` debe estar limpio — el clean-tree gate del checkout principal no ve un worktree con trabajo en vuelo. Si el estado del agente no puede establecerse, no hay reset: en interactivo la skill lo expone y pregunta; en autonomous → terminal `FAILED` con el estado preservado. Auto-reset en autonomous solo con mismatch + agente inactivo verificado + worktree limpio, anotado en el log (nunca un segundo implementador contra el mismo intento).
7. **Continuaciones** — `IMPLEMENTATION_PARTIAL` → continuar el MISMO subagente vía `SendMessage` (conserva su contexto, análogo al resume del hilo B), con el mismo cap `$TANDEM_IMPL_ROUNDS` (default 2, leído del estado durable, nunca de memoria) y las mismas reglas de takeover. Si el subagente ya no existe (compactación, sesión nueva): subagente fresco cuyo contexto de recovery incluye el plan, `git status -s`, el diff tracked, la orden de **leer completo cada archivo untracked (`??`)** — invisibles para `git diff` — y la lista de pendientes del último informe persistido.
8. **`TANDEM_CRITICAL` bajo opus** — el tool Agent no expone effort; se documenta que con `opus` la variable no cambia el esfuerzo (sí mantiene su otro significado: review nunca omitida). Con `sol` conserva su semántica completa (high→xhigh).
9. **Modo autónomo** — sin cambios de semántica: mismos sentinels, mismos caps (aplicados desde el estado durable), mismos estados terminales (`PARTIAL` tras el cap no avanza a review). El transporte claude corre dentro de la sesión, así que no añade interacción.

Cambios de documentación y política (mismo release):

- `skills/run/SKILL.md` — diagrama de fases y calibración de riesgo: "Opus 5 implementa (default); Sol vía `TANDEM_IMPLEMENTER=sol`".
- `docs/ARCHITECTURE.md` — nodo L del mermaid (implementador seleccionable), regla de hilos (el "hilo B" es un subagente Claude continuado vía SendMessage cuando el implementador es opus, con estado espejo en `.tandem/state/implement-claude/`), y una nota nueva de sesgo de árbitro: con opus, Fable arbitra hallazgos de Sol sobre código de su propia familia — el estándar de evidencia `file:line` y disposición razonada por hallazgo es la mitigación y no se relaja.
- `README.md` — matriz de roles (fila implementador con ambos transportes y sus fronteras: allowlist harness vs sandbox OS), lista de overrides (+`TANDEM_IMPLEMENTER`), y aviso destacado de cambio de comportamiento del default.
- `scripts/codex-doctor.sh` — la sección de política muestra el implementador efectivo según `TANDEM_IMPLEMENTER` (línea `implementer:`), con la política Codex como rama `sol`; un valor desconocido de `TANDEM_IMPLEMENTER` es una línea **FAIL** (config inválida = fail-fast, igual que el resto de doctor).
- `.claude-plugin/plugin.json` — versión 0.9.0 y descripción actualizada ("Opus 5 implementa por defecto; Sol hace red-team y review independiente").
- `.claude-plugin/marketplace.json` — ambas descripciones (raíz y entrada del plugin) dejan de afirmar que Codex implementa; misma historia que plugin.json.
- `CHANGELOG.md` — entrada 0.9.0 destacando el cambio de default y el rollback de una variable.

## Key decisions & tradeoffs

- **Opus 5 como default, no opt-in.** Rompe el comportamiento de instalaciones existentes (0.x, se anuncia en CHANGELOG y README). La alternativa conservadora (Sol default hasta tener frontera OS equivalente) fue planteada por el revisor y **rechazada como decisión humana explícita** en el gate de entrevista: la diversidad generador/revisor pasa a ser la configuración canónica y el rollback es una variable.
- **Frontera del implementador claude: allowlist de harness, no sandbox OS.** El agent type restringido elimina el acceso a MCP/conectores/red por herramienta; no puede impedir que Bash ejecute `git push`. Mitigaciones apiladas: prohibición en system prompt + verificación de Fable (estado de rama y remotos antes del gate) + commit exclusivo de Fable tras aprobación. Hooks de bloqueo por comando quedan explícitamente para una versión futura.
- **Dos valores en v1 (`opus`|`sol`), no un model-picker genérico.** `sonnet`/`fable`/`haiku` como implementadores quedan fuera: cada valor nuevo es superficie de prueba y la matriz de riesgo solo respalda estos dos. Valor desconocido → error (skill y doctor), no fallback.
- **In-place en `tandem/<slug>` por defecto.** `TANDEM_WORKTREE=1` sigue siendo el aislamiento opt-in, ahora con protocolo explícito de cwd para el subagente (hallazgo P1-2 del red-team).
- **Sin heartbeat/status line para el transporte claude (v1).** La línea 2 de la status line no aparece durante una implementación con opus; Claude Code ya muestra el progreso del subagente de forma nativa. Limitación documentada.
- **`_common.sh` intacto.** `resolve_role implement` sigue siendo la política Codex de la rama `sol`; el selector vive en la skill y en doctor, no en los scripts de transporte Codex.

## Files to touch

| Archivo | Cambio |
| --- | --- |
| `skills/implement/SKILL.md` | Núcleo: selector, transporte claude (agent type, preflight de modelo, lanzamiento, worktree explícito, estado durable, continuaciones/recovery, sentinels), semántica de `TANDEM_CRITICAL`, transporte sol intacto |
| `agents/implementer.md` | Nuevo: agent type restringido (allowlist mínima, `model: opus`, prohibiciones en system prompt) |
| `skills/implement/prompts/implement-claude.tpl` | Nuevo: prompt del subagente (plan, ruta de trabajo, contrato de informe + sentinel + modelo auto-reportado) |
| `skills/run/SKILL.md` | Pipeline y calibración de riesgo con el implementador seleccionable |
| `docs/ARCHITECTURE.md` | Mermaid (nodo L), regla de hilos + estado espejo, nota de sesgo de árbitro, matriz de riesgo |
| `README.md` | Matriz de roles con fronteras, overrides, aviso de nuevo default |
| `scripts/codex-doctor.sh` | Línea `implementer:` según selector; FAIL con valor desconocido |
| `.claude-plugin/plugin.json` | `version` 0.9.0, `description` actualizada |
| `.claude-plugin/marketplace.json` | Descripciones coherentes con el nuevo default |
| `CHANGELOG.md` | Entrada 0.9.0 |

## Acceptance & proof

Casos de aceptación:

1. Sin `TANDEM_IMPLEMENTER` definida, `tandem:implement` instruye el transporte claude (agent type `tandem:implementer`, preflight de `CLAUDE_CODE_SUBAGENT_MODEL`, contrato de sentinel/informe); ningún paso invoca `codex-start.sh implement`.
2. Con `TANDEM_IMPLEMENTER=sol`, el flujo es byte-a-byte el actual (mismos comandos, mismos templates, `TANDEM_CRITICAL` sube effort a xhigh).
3. Valor desconocido (`TANDEM_IMPLEMENTER=gemini`) → la skill ordena parar antes de tocar nada y `codex-doctor.sh` emite FAIL.
4. Las reglas de PARTIAL (cap de continuaciones desde estado durable, takeover, recovery con untracked leídos, autonomous no avanza a review con PARTIAL) están especificadas para ambos transportes.
5. Con `TANDEM_WORKTREE=1`, la skill fija la ruta absoluta del worktree en el prompt del subagente y ancla verificación y testing gate a ese cwd.
6. `codex-doctor.sh` muestra el implementador efectivo bajo cada valor del selector.
7. README, ARCHITECTURE, run, CHANGELOG, plugin.json y marketplace.json cuentan la misma historia (sin restos de "Sol/Codex implementa" como default).
8. Estado durable: `plan_hash` es el blob commiteado (marcar checkboxes en la working copy NO invalida la continuación); identidad coincidente permite reanudar o reset deliberado, mismatch solo descartar o parar; ningún reset ocurre sin el guard de liveness (agente inactivo + worktree registrado limpio), y en autonomous cualquier duda es `FAILED` con estado preservado.

PROOF (un único `bash -e` sobre el bloque; el smoke de doctor separa salida y exit status — éxito exige exit 0 **y** la línea de política; el valor inválido exige exit no-cero **y** el FAIL específico del selector, para no confundirlo con un doctor roto por otra causa):

```bash
set -euo pipefail
bash -n scripts/*.sh
for f in README.md docs/ARCHITECTURE.md CHANGELOG.md skills/implement/SKILL.md skills/run/SKILL.md scripts/codex-doctor.sh; do
  grep -q TANDEM_IMPLEMENTER "$f"
done
test -f skills/implement/prompts/implement-claude.tpl
test -f agents/implementer.md
jq -e '.version == "0.9.0" and (.description | test("Opus"))' .claude-plugin/plugin.json >/dev/null
jq -e '[.description, .plugins[0].description]
       | all(. != null and test("Opus") and (test("Codex.*implementa") | not))' \
  .claude-plugin/marketplace.json >/dev/null
d0="$(bash scripts/codex-doctor.sh)"
printf '%s\n' "$d0" | grep -q 'implementer:.*opus'
ds="$(TANDEM_IMPLEMENTER=sol bash scripts/codex-doctor.sh)"
printf '%s\n' "$ds" | grep -q 'implementer:.*sol'
if dg="$(TANDEM_IMPLEMENTER=gemini bash scripts/codex-doctor.sh 2>&1)"; then
  echo 'doctor aceptó un selector inválido' >&2; exit 1
fi
printf '%s\n' "$dg" | grep -q 'FAIL.*TANDEM_IMPLEMENTER'
echo PROOF-OK
```

Los casos 1, 2, 4 y 5 son prosa de skill que ejecuta Fable: se verifican por lectura en la review de código (transporte sol además por diff vacío sobre los comandos actuales), como en todos los releases anteriores de este repo — un smoke automatizado que lance subagentes Opus reales no es determinista ni gratuito y se rechaza a propósito.

## Risks

- **Bash sin sandbox OS en el transporte claude**: el allowlist del agent type bloquea MCP/red por herramienta, pero Bash permite `git push` u operaciones fuera del repo si los permisos de la sesión lo permiten. Mitigación apilada: prohibiciones en system prompt y template, verificación de Fable (rama, remotos, `git log`) antes del gate, commit exclusivo de Fable. Hooks PreToolUse de bloqueo por comando: versión futura.
- **Fallback silencioso de modelo**: precedencias externas (`CLAUDE_CODE_SUBAGENT_MODEL`, allowlists de organización) pueden sustituir a opus. Mitigación: preflight fail-closed sobre la variable + modelo auto-reportado en el informe; verificación runtime robusta documentada como no disponible.
- **Sesgo de árbitro same-family**: Fable arbitrando hallazgos de Sol contra código Claude. Mitigación: estándar de evidencia sin relajar + gates humanos; documentado en ARCHITECTURE.
- **Pérdida del subagente** entre sesiones/compactación. Mitigación: estado durable en `.tandem/state/implement-claude/` (rondas, sentinel, informes) + protocolo de recovery con untracked incluidos.
- **Cambio de default** sorprende a usuarios existentes. Mitigación: CHANGELOG + README lo destacan; rollback = `TANDEM_IMPLEMENTER=sol`.
- **Status line muda** durante implementaciones opus (aceptado, documentado).

## Out of scope

- Cambiar los revisores (Sol sigue en plan red-team y review final) o hacerlos seleccionables.
- `tandem:ultra` (seats read-only, nunca implementan), `tandem:image`, fase 2 MCP.
- Heartbeat/status line para el transporte claude.
- Hooks PreToolUse para bloquear comandos git del subagente (evaluar en 0.10).
- Implementadores adicionales (`sonnet`, `fable`, `haiku`) — evaluar tras uso real.
- Política de release/merge (fuera del alcance de tandem por diseño).
