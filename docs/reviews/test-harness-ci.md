# Review: test-harness-ci (v0.10.0)

- **Fecha:** 2026-07-30
- **Plan:** docs/plans/test-harness-ci.plan.md (backlog M14)
- **Rama:** tandem/test-harness-ci sobre main (base a5f3058)
- **Testing gate:** lint (shellcheck 0.10.0 pineado): OK · actionlint 1.7.7 pineado: OK ·
  tests: 44 passed, 0 failed (`TESTS_BASH=/bin/bash` 3.2.57) · proof (`bash
  tests/verify.sh`): OK

## Plan review (Sol, xhigh, read-only)

4 rondas de 5 → **APPROVED**. 11 hallazgos (2 P1, 9 P2), 11 aceptados, 0 rechazados.
Destacados: el lint bloqueante habría nacido en rojo (SC1010 en `hb_end done`, reproducido
localmente antes de aceptar), el snapshot del heartbeat del stub era incorrecto en
worktrees, `/usr/bin/jq` hace inocultable a jq sin un symlink farm mínimo, los background
jobs de bash no reciben grupo de procesos propio sin `set -m`, el contexto `secrets` en
`jobs.<id>.if` invalida el workflow entero al parsear, y un smoke solo-pineado nunca
detectaría el drift contra el `@latest` que instruye el README.

## Implementación

Transporte Opus (subagente `general-purpose` con `model: opus` y allowlist contractual —
el agent type `tandem:implementer` no existe en sesiones sin el plugin instalado; desviación
aprobada explícitamente en gate humano y registrada). `IMPLEMENTATION_PARTIAL` honesto: todo
implementado salvo pinear los sha256 (red prohibida por contrato); takeover de Fable — 8
assets descargados y pineados, gate completo ejecutado. Baseline de seguridad limpio: cero
commits del implementador, HEAD y remotos intactos.

## Code review (Sol, hilo nuevo e independiente, xhigh, read-only)

4 rondas (3 + 1 extra autorizada por gate humano tras el cap) → **APPROVED**. 7 hallazgos,
7 aceptados y corregidos por Fable, 0 rebatidos:

1. (Major, r1) El cache de binarios lint se ejecutaba sin re-verificación de checksum →
   solo se cachean archivos de release; sha256 pineado re-verificado en cada ejecución.
2. (Major, r1) `check-drift.sh` sin tipos JSON y con clases de evento imposibles para una
   captura mínima → `key:jsontype` + dos niveles (requerido/condicional-advisory), con test
   propio de semánticas.
3. (Minor, r1) `-gt` sobre pid sin sanear en statusline (stderr con heartbeat corrupto) →
   saneado + aserción de stderr por invocación en never-fail.
4. (Major, r2) `provision()` sin `-e` podía ejecutar un binario preexistente si `cp`
   fallaba → staging atómico: probe de versión SOLO sobre el fichero staged, publicación
   por `mv` verificado; test de impostor no reemplazable que jamás se ejecuta.
5. (Minor, r2) Changelog desactualizado por los propios fixes → recuentos y cuarto bug.
6. (Major, r3, verificado empíricamente por el revisor) `TANDEM_VERIFY_LIB=1` ejecutado
   (no sourceado) era un gate verde silencioso → modo librería solo bajo sourcing genuino
   (`BASH_SOURCE[0] != $0`); ejecución directa rechaza con rc 2 ruidoso, con test.
7. (r4) Re-verificación del fix 6 → APPROVED, sin problemas nuevos.

## Veredicto

Los tres gates (plan APPROVED, testing gate verde, code review APPROVED) se cumplieron sin
excepciones ni aprobaciones por agotamiento; la única extensión (ronda 4 del code review)
fue una decisión humana explícita registrada en el log.
