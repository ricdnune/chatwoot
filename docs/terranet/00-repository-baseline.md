# 00 — Baseline del repositorio (M0)

Fecha de captura: 2026-10-27 · Equipo: Linux Mint 22.3 (kernel 7.0.0-34) · Checkout: `~/Projects/chatwoot`

Convención: **FACT** = verificado con comando/archivo en este checkout · **INFERENCE** = hipótesis · **DECISION** = propuesta pendiente de aprobación.

## 1. Estado del checkout al empezar (solo lectura)

| Dato | Valor | Evidencia |
|---|---|---|
| Directorio | `/home/ricdnune/Projects/chatwoot` | `pwd` |
| Rama inicial | `develop` | `git branch --show-current` |
| SHA inicial (`HEAD`) | `90ed589c695f6aeaeea0e78f6be7d4ec0fb3e1b3` | `git rev-parse HEAD` |
| Working tree | limpio (0 cambios) | `git status --short` vacío |
| `git diff --check` | sin problemas (rc=0) | — |
| `VERSION_CW` | `4.19.1` | `cat VERSION_CW` |
| `.ruby-version` / `.nvmrc` | `3.4.4` / `24.22.1` | `cat` |
| Remotos al empezar | solo `origin` → `https://github.com/ricdnune/chatwoot.git` | `git remote -v` |

**FACT** — `develop` del fork == `upstream/develop` == `90ed589c69…` (0 commits de diferencia en ambos sentidos; `origin/develop` también coincide). Esto reconfirma la auditoría remota del 27-10-2026 citada en el prompt.

## 2. Remotos y ramas (acciones realizadas)

- `upstream` **no existía**; se agregó con la URL mostrada: `https://github.com/chatwoot/chatwoot.git` y se ejecutó `git fetch upstream --tags`. No se hizo merge, rebase, reset ni pull.
- Release estable seleccionado (**DECISION**): **`v4.19.1`** (tag anotado `c5c325a0bbc949339dd688d31e3f73cf0b272906` → commit `caab07a8f00032d5205b5a5d7e2eb0ba2f3d2d82`, == `upstream/master`).
- `develop` está **9 commits por delante** de `v4.19.1` (features nuevas sin release: voz Twilio, Shopify, avatares Captain, etc.). **DECISION:** Terranet se basa en el tag estable, no en `develop`.
- Ramas locales creadas (solo locales, sin push):

| Rama | Base | Propósito |
|---|---|---|
| `terranet/main` | `v4.19.1` (`caab07a8f0`) | línea Terranet estable; recibirá releases upstream pinneadas |
| `terranet/feature/m0-m1-baseline-lab` | `terranet/main` | esta iteración (docs + laboratorio) |
| `terranet/release/*` | — | propuesta, aún no creada |
| `develop` | sin tocar | espejo de upstream; no se modifica |

- Nombres propuestos: `terranet/feature/<hito>-<tema>` (p. ej. `m2-privacy-egress`, `m3-branding`, `m4-isp-context`), `terranet/release/<chatwoot-version>-tn.<n>` (p. ej. `4.19.1-tn.1`).

## 3. Toolchain: requerido vs. disponible en el host

| Herramienta | Requerido (FACT, lockfiles/CI) | En el host (FACT) | Estado |
|---|---|---|---|
| Ruby | `3.4.4` (`Gemfile`, `.ruby-version`) | `3.2.3` del sistema; **sin rbenv** | ❌ no sirve |
| Bundler | `2.5.16` (Dockerfile) | no instalado | ❌ |
| Node | `24.22.1` (`.nvmrc`, `engines: 24.x`) | `22.23.2` | ❌ |
| pnpm | `10.2.0` (`packageManager`) | vía corepack (descarga pendiente) | ⚠️ |
| PostgreSQL | `pgvector/pgvector:pg16` (compose/CI) | cliente no instalado | usar contenedor |
| Redis | `redis:alpine` | no instalado | usar contenedor |
| Docker | — | Engine 29.8.1, Compose v5.5.1 | ✅ |
| Hardware | — | 24 CPU, 62 GiB RAM, 709 GB libres | ✅ |

**DECISION:** el laboratorio se ejecuta **en Docker** (Ruby/Node exactos dentro de contenedor) en vez de instalar rbenv/nvm en el host. Evita tocar el entorno de otros proyectos (`terranet-rrhh`, `crm-ia` corren en este mismo Docker; el lab usa proyecto compose, red y volúmenes propios `terranet-lab_*`).

## 4. Versiones efectivas (FACT)

Rails `7.2.3.1` · Sidekiq `7.3.10` · pg `1.5.3` · Devise `4.9.4` · Pundit `2.3.0` · redis-rb `5.0.6` · vite_rails `3.10.0` · aws-sdk-s3 `1.208.0` · rest-client `2.1.0` · httparty `0.24.0`
Vue `^3.5.12` · Vite `6.4.2` · Vitest `3.0.5` · Tailwind `^3.4.19` · Pinia `^3.0.4` · Vuex `~4.1.0` · `@sentry/vue ^8.55.0` · `@amplitude/analytics-browser ^2.11.10`
Esquema: `db/schema.rb` versión `2026_10_19_143116`, 108 `create_table`, 204 archivos en `db/migrate`.
Tamaño: 677 archivos versionados bajo `enterprise/`, 5 305 bajo `app/javascript/`.

## 5. Licencias (resumen; detalle de riesgos en cada doc)

- `LICENSE` (sha256 `602d38a8…2175d`): MIT Expat para todo lo que no esté bajo `enterprise/`; terceros bajo su propia licencia.
- `enterprise/LICENSE` (sha256 `4c7b8e19…70207`): **uso en producción solo con suscripción/acuerdo vigente** y asientos correctos; permite copiar/modificar **para desarrollo y pruebas sin suscripción**; prohíbe copiar, publicar, distribuir, sublicenciar o vender. Modificaciones y parches quedan bajo los mismos límites.
- **FACT** — `ChatwootApp.enterprise?` es verdadero si existe el directorio `enterprise/` salvo que `DISABLE_ENTERPRISE` esté definido (`lib/chatwoot_app.rb:14-17`). `ChatwootHub.pricing_plan` devuelve `community` sin plan instalado.
- **FACT** — `config/features.yml` marca como `premium: true` (entre otras) `disable_branding`; `enterprise/config/premium_features.yml` lista `disable_branding, audit_logs, sla, custom_roles, captain_*, …`.
- **FACT** — En Super Admin la edición de la sección `custom_branding` (LOGO, BRAND_NAME, INSTALLATION_NAME, …) solo existe en `enterprise/app/controllers/enterprise/super_admin/app_configs_controller.rb` y solo cuando `pricing_plan != 'community'`; el controlador comunitario no la mapea (`app/controllers/super_admin/app_configs_controller.rb:59-80`).
- **LICENSE FLAG:** el uso interno **no** elimina estos límites. Ver `docs/terranet/02-branding-inventory.md` §5 y `docs/upstream/chatwoot-customizations.md`. La decisión (A licenciar / B edición MIT separada) es **humana**; esta iteración no habilita ni evita ningún gate.
- Marcas/trademarks: no investigadas todavía (pendiente, ver `NEXT STEPS` del reporte).

## 6. Hallazgos de la baseline que afectan el plan

1. **FACT** — No hay `upstream` configurado de fábrica; agregado ahora (§2).
2. **FACT** — Host sin Ruby 3.4.4 / Node 24 → laboratorio en Docker (§3).
3. **FACT** — `docker-compose.yaml` oficial publica Postgres y Redis en `0.0.0.0:5432/6379` y usa `mailhog/mailhog`; el lab Terranet no lo usa (ver `01-local-development.md`).
4. **FACT** — `.env.example` trae `ENABLE_PUSH_RELAY_SERVER=true` y **no** menciona `DISABLE_TELEMETRY` (ver `03-privacy-egress-audit.md`).
5. **FACT** — `docker-compose.production.yaml` usa `chatwoot/chatwoot:latest` (imagen flotante): contradice la regla de releases pinneados; no usar tal cual.

## 7. Comandos de baseline reproducibles

```bash
cd ~/Projects/chatwoot
git remote -v && git status --short && git branch --show-current && git rev-parse HEAD
git fetch upstream --tags            # solo herramientas de desarrollo; nunca merge automático
git rev-parse upstream/develop v4.19.1^{commit}
git rev-list --left-right --count develop...upstream/develop
cat VERSION_CW .ruby-version .nvmrc
```
