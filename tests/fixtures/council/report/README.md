# Fixtures de `council.sh report`

Alimentan `tests/council-report.test.sh` y `tests/council-report-fresh.test.sh`. Todo es
SINTÉTICO, escrito a mano para cubrir la gramática del consejo; ningún dato procede de un run
real.

| Fichero | Qué es |
| --- | --- |
| `doc/` | los documentos de un run de dos rondas (A = líder, B = Astra, C = Fable): brief, propuestas, contrainterrogatorio, síntesis v1 y v2, auditorías, registro, rondas e `informe.md` |
| `metadatos.expected.md` | el `metadatos.md` que escribe `status --metadata` sobre el run sembrado por `council-report.test.sh` (`doc/` más el `run.json`, los usage y los `meta.json` que siembra el test) |
| `metadatos-vacio.expected.md` | el de un run recién creado, sin turnos ni rondas: todas las ramas vacías |

Los dos `metadatos*.expected.md` se generaron con el `scripts/council.sh` de c0d8cf1 (v0.36.1),
ANTES del refactor de `write_metadata` que comparte sus hechos con `report`, y el test exige
que la salida siga siendo idéntica byte a byte. Si un cambio posterior altera `metadatos.md` a
propósito, se regeneran a la vez que ese cambio y se dice en su commit.

Los perfiles de esfuerzo los regeneraron cambiando SOLO las líneas que describe su plan: la
línea `- Perfil: …` tras «Creado…», la fila del líder (`/ <nivel>` y su evidencia medida, aquí
«no medido») y la de Fable (los esfuerzos medidos en lugar del literal «frontmatter»). El run
sembrado lleva un `perfil` `critico` y capturas con `esfuerzo`/`agente`; el vacío, ninguno.

Lo que siembra `doc/` a propósito:

- `1-propuestas/B.md` lleva texto hostil (`</script><script>…`, `<!--`, `<img onerror>`,
  enlaces `javascript:` y `data:`) y bytes raros (`\ $ & ñ «»`): ninguno puede cerrar el bloque
  de datos del HTML y todos se embeben byte a byte.
- `2-contrainterrogatorio/B.md` cita un ID ajeno (`[C-1] [P3]`) y `rondas/r1-C.md` un estado
  ajeno (`[B-2] NO RESUELTA`): son referencias, nunca afirmaciones de quien las cita.
- `rondas/r1-B.md` deja un `NO RESUELTA` y abre `B-3`; `rondas/r2-C.md` un `REABRE` que resuelve
  en la misma respuesta.
- `auditoria-v2.md` tiene una fuente cuya descripción contiene a su vez « — » (se parte por el
  primero) y otra que no es una URL.
- `informe.md` sigue las secciones fijas del paso 6, con tablas de fechas en español.
