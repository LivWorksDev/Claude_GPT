# Review: worktree-sandbox-pins (v0.11.0)

- **Fecha:** 2026-07-30
- **Plan:** docs/plans/worktree-sandbox-pins.plan.md (backlog M1 + M2 + M4)
- **Rama:** tandem/worktree-sandbox-pins sobre main (base 3d77d52)
- **Testing gate:** lint (shellcheck 0.10.0 pineado): OK · actionlint 1.7.7 pineado: OK ·
  tests: 49 passed, 0 failed (`TESTS_BASH=/bin/bash` 3.2.57) · proof (`bash
  tests/verify.sh`): OK

## Enjambre ultra previo (run `m1m2-plan`)

3 workers Sol `high` (sandbox/red, worktree/cwd, tests/CI) + 1 judge Sol `xhigh` de
refutación. 9 hallazgos, **7 confirmados, 2 refutados** por scope creep (anclar `ask`/`image`
—fuera de M1 por diseño— y canonicalizar rutas con `pwd -P` —contrato nuevo innecesario—),
ambos recogidos como decisiones explícitas del plan. Conclusión de fondo: la v1 del plan era
**insuficiente para su propio goal**.

## Plan review (Sol, xhigh, read-only)

4 rondas de 5 → **APPROVED**. 9 hallazgos, 9 aceptados. Los dos que cambiaron el diseño:

1. Pinear claves una a una nunca cubre lo no enumerado (MCP con red, execpolicies, claves
   futuras) → `--ignore-user-config` + `--ignore-rules`, con los pins como defensa en
   profundidad. Verificado que los `-c` siguen aplicándose y validándose con el flag.
2. La prueba de M1 no podía detectar el fallo de M1: la lógica vivía en Markdown y ningún
   test la ejecuta → helper `worktree-root.sh` + test de contrato sobre las skills.

También: el contrato de la review debía cubrir los pasos 0–4 (el **commit final** estaba en
el hueco); CHANGELOG y bump pasan a ser propiedad del orquestador porque ambos transportes
de implementación los prohíben; el probe de drift debe usar `debug prompt-input` y no
`codex exec` (con `exec`, el caso que busca detectar arrancaría un turno real).

## Implementación

Transporte Opus (subagente con allowlist contractual; `tandem:implementer` no existe en
sesiones sin el plugin instalado — desviación aprobada en gate humano, igual que en M14).
`IMPLEMENTATION_COMPLETE`. Baseline limpio: cero commits del implementador, HEAD y remotos
intactos. Tres juicios propios del implementador aceptados: exit 65 para los fallos del
resolver, pin de `web_search` derivado de `CODEX_SANDBOX` en vez de una lista de roles, y un
preflight en el probe (sin él, un subcomando renombrado haría parecer muertas las cinco
claves y el informe culparía a los pins).

## Code review (Sol, hilo nuevo e independiente, xhigh, read-only)

4 rondas (3 + 1 extra autorizada por gate humano tras el cap) → **APPROVED**. 7 hallazgos,
7 aceptados, 0 rebatidos:

1. (Major, r1) Los resumes saltaban la resolución del working root y el recovery leía el
   árbol equivocado → Step 0 ramifica explícitamente fresh vs resume.
2. (Major, r1) La vigilancia de drift no corría sin `OPENAI_API_KEY`, pese a no necesitar
   credenciales → job `config-drift` sin gate; el secret queda solo en los turnos de modelo.
3. (Minor, r1) El test de contrato contaba bloques enteros → parsea comandos lógicos;
   verificado por mutación.
4. (Minor, r1) Checkbox del plan sin marcar.
5. (Minor, r2) Referencias obsoletas al layout de jobs anterior.
6. (Major, r3) Una limpieza con regex borró la señal de fallo del job de drift: un pin
   muerto habría dejado el job semanal en verde — justo lo que la pieza existe para evitar.
7. (r4) Re-verificación del fix 6 → APPROVED, sin problemas nuevos.

## Veredicto

Los tres gates (plan APPROVED, testing gate verde, code review APPROVED) se cumplieron sin
aprobaciones por agotamiento. La única extensión —la ronda 4 del code review— fue decisión
humana explícita registrada en el log. Cuatro de los siete hallazgos del code review eran
defectos introducidos por Fable al corregir otros: el argumento más concreto a favor de que
el revisor final llegue sin contexto previo.
