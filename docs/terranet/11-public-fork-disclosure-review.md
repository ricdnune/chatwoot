# 11 — Revisión de divulgación del fork público (M4, 2026-10-27)

El fork `ricdnune/chatwoot` es **público**: cada commit publicado debe tratarse como divulgado de forma irreversible (puede haber sido clonado, indexado o cacheado aunque se borre después). Este documento revisa **qué revelan las ramas ya publicadas sobre la infraestructura y las personas de Terranet**, qué se hizo y qué se recomienda. No se reescribió historia, no se borró nada y no se cambió la visibilidad del repositorio: esas decisiones son del propietario.

Convención: **FACT** (comprobado en el repositorio) · **INFERENCE** · **DECISION** (pendiente del propietario).
Alcance revisado: las 6 ramas publicadas antes de esta misión (`m0-m1`, `m2`, `m3-0`, `m3-branding`, `m4-0`, `m2-1`) y los archivos que cada una añade sobre `v4.19.1`.

## 1. Método
1. `gitleaks` (imagen oficial) sobre el rango de cada push: **0 hallazgos** (FACT). Detecta secretos, **no** información de infraestructura.
2. Búsqueda dirigida en los archivos añadidos por las ramas: nombres de nodos, hipervisores, hostnames de producción, dominios, correos, IPs, rutas locales, buckets, proveedores de túnel/almacenamiento.
3. Metadatos de commits (autor/correo) y capturas de pantalla (`docs/terranet/evidence/`).

## 2. Hallazgos

| # | Severidad | Hallazgo (FACT) | Dónde | Por qué importa |
|---|---|---|---|---|
| D1 | **Media** | La documentación de guardarraíles de HA **nombra los dos nodos de hipervisor de producción**, describe una topología de **dos nodos con la misma pila**, y menciona el uso de **almacenamiento de objetos y túnel de un proveedor concreto** para producción. | `docs/terranet/05-ha-production-guardrails.md` (varias líneas); menciones menores en `03` §11, `06` §6–7 | Mapa de reconocimiento para un atacante: qué atacar, qué proveedor suplantar, qué dependencias de disponibilidad existen. Ninguna línea contiene IPs, credenciales ni nombres de bucket. |
| D2 | **Media** | El **hostname de producción** aparece junto a esa descripción de infraestructura. | `docs/terranet/05-…` (alcance y restricciones) | Enlaza el dominio público real con la topología de D1. |
| D3 | **Media** | **Todos los commits Terranet llevan un correo corporativo** del dominio de la empresa en los metadatos del autor. | `git log` (inmutable salvo reescritura) | Confirma públicamente la relación fork ↔ empresa y expone un buzón real a spam/phishing dirigido. |
| D4 | Baja | Ruta absoluta local con el **nombre de usuario del sistema**. | `docs/terranet/00-repository-baseline.md` | Revela el usuario de la máquina de desarrollo. |
| D5 | Baja | `BRAND_URL`/`WIDGET_BRAND_URL` con el dominio corporativo (suposición pendiente de confirmar). | `config/terranet/branding.yml` | Es un dominio público de marca; sin riesgo adicional. |
| D6 | Informativa | Rangos de red del laboratorio (`172.29.250.0/24`) y puertos loopback. | `terranet/lab/*`, `docs/terranet/01` | Direccionamiento **solo del laboratorio**, no de producción. |
| D7 | OK | Capturas (`evidence/m3`, `evidence/m4`): solo datos sintéticos del seed (usuario, cuenta y contactos ficticios) y `127.0.0.1`; sin hostnames reales, sin tokens. Los tokens de las pruebas son literales `mock-…` y nunca aparecen en pantalla. | `docs/terranet/evidence/` | — |
| D8 | OK | No hay volcados, `.env`, llaves, IPs de producción, nombres de bucket, números de teléfono ni datos de abonados. Los valores secretos del `.env` del laboratorio no están en el historial. | todas las ramas | — |

**INFERENCE (D1–D3):** por sí solos son datos de bajo valor, pero agregados reducen el coste de un ataque dirigido. Se tratan como **ya divulgados**.

## 3. Acciones realizadas en esta misión (sin tocar el historial)
- **Los documentos nuevos (`07`, `08`, este `11`, `12`) no añaden** nombres de nodos, hostnames de producción, proveedores de infraestructura ni correos. Lo nuevo se redacta en términos genéricos ("nodos de producción", "almacenamiento de objetos").
- **Control manual de divulgación antes de cada push**, además de gitleaks: `terranet/tools/disclosure_scan.sh` (patrones genéricos versionados + patrones propios en un archivo **ignorado por git** donde sí pueden ir los nombres sensibles, sin publicarlos) y atestación explícita `TERRANET_DISCLOSURE_REVIEWED=1` exigida por el hook `pre-push`. Detalle en `09`.
- Verificado que las capturas nuevas no contienen datos reales (D7).

## 4. Remediaciones propuestas (decisión del propietario)
1. **Aceptar el riesgo** de D1–D3 como divulgado y **generalizar hacia adelante**: un commit que sustituya en `05`, `03`, `06` los nombres concretos por términos genéricos. Reduce nuevas indexaciones, **no** borra lo ya publicado.
2. **Mover la documentación operativa sensible a un repositorio privado** (recomendado): `05`, planes de HA/runbooks, inventario de producción. El fork público conserva solo código y documentación genérica. **No se cambió la visibilidad del fork**; si se quiere un fork privado, GitHub no permite cambiar la visibilidad de un fork público de un repositorio público: habría que crear un repositorio nuevo (no fork) y empujar allí.
3. **Correo del autor (D3):** configurar para los commits futuros un correo `noreply` de GitHub (`git config user.email <id>+<usuario>@users.noreply.github.com`) y activar en GitHub «Keep my email addresses private» + «Block command line pushes that expose my email». Los commits ya publicados mantienen el correo actual.
4. **Reescritura de historial (no recomendada y no realizada):** `git filter-repo` + force-push de ramas nuevas eliminaría D1–D4 del historial *de este fork*, pero no de clones/cachés previos, rompe SHAs citados en informes/PR y requiere autorización explícita (el repositorio prohíbe `push --force`). Solo valdría la pena si se decide que la información es crítica **y** se rotan/aíslan los activos afectados.
5. **Endurecimiento paralelo, independiente de lo publicado:** asumir que el reconocimiento ya existe → mantener segmentación y acceso administrativo restringido a producción, MFA en consolas de hipervisor y de proveedor, y alertas de acceso. (Fuera del alcance de este repositorio.)
6. Revisión del texto de PR/Issues/Discussions del fork antes de abrirlos: son públicos y se indexan igual que los commits.

## 5. Qué NO se concluye
- No se ha verificado que **no existan otros forks o clones** con copias de lo publicado.
- No se ha auditado la configuración de la cuenta de GitHub (2FA, claves SSH, tokens personales); está fuera de este repositorio.
- El escaneo por patrones es heurístico: la ausencia de hallazgos no prueba la ausencia de información sensible.
