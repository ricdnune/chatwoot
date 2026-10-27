# 01 — Laboratorio local aislado (M1)

Rama: `terranet/feature/m0-m1-baseline-lab` (sobre `terranet/main` = `v4.19.1`). Todo lo de este documento fue ejecutado el 2026-10-27 en Linux Mint 22.3; los resultados están en §6. **Sin secretos**: los valores del `.env` se generan al azar y no se versionan.

## 1. Diseño y garantías de aislamiento (FACT, verificado)

```
host 127.0.0.1:13000 (Rails) · :3036 (Vite) · :18025 (Mailpit UI)
        │  solo loopback, nunca 0.0.0.0
   ┌────▼─────┐ lab_edge (con salida)       lab_internal (internal: true, SIN ruta externa)
   │ gateway  ├──────────────┐   ┌──────────────────────────────────────────────────────┐
   │ (socat)  │              └──▶│ rails · sidekiq · vite · postgres · redis · mailpit  │
   └──────────┘                  │ dns-sink 172.29.250.2 (resuelve todo lo ajeno a 192.0.2.1 y lo registra) │
                                 └──────────────────────────────────────────────────────┘
```

- Proyecto Compose `terranet-lab`; redes y volúmenes propios (`terranet-lab_*`). No toca los contenedores de `terranet-rrhh` ni `crm-ia` que corren en el mismo Docker.
- Imagen construida con el **`docker/Dockerfile` oficial sin modificar** (Ruby 3.4.4-alpine, Node 24.22.1, pnpm 10.2.0, bundler 2.5.16) → `terranet-chatwoot-lab:4.19.1-dev` (3.39 GB).
- Mailpit (en lugar del `mailhog` abandonado) y almacenamiento local (`ACTIVE_STORAGE_SERVICE=local`). No hay R2, SMTP, Redis ni DB de producción en ninguna variable.
- Prueba de aislamiento realizada: desde `rails`, `getent hosts hub.2.chatwoot.com` → `192.0.2.1` (sumidero); `wget` a HTTPS externo falla; `wget http://1.1.1.1` → *Network unreachable*.
- **Alcance de la garantía:** el contenedor no puede salir a Internet. El **navegador del desarrollador** no está dentro de esa red; su tráfico se audita aparte (DevTools) — ver `03-privacy-egress-audit.md`.

## 2. Requisitos

| Requisito | Versión probada |
|---|---|
| Docker Engine + Compose v2 | 29.8.1 / v5.5.1 |
| `openssl`, `curl`, `bash`, `git` | del sistema |
| Disco | ~8 GB (imagen + volúmenes) |
| Internet | solo para `build` (imágenes base, gems, paquetes npm) y `git fetch upstream`; **no** para ejecutar el lab |

No se necesita Ruby, Node, rbenv ni PostgreSQL en el host.

## 3. Puesta en marcha (comandos exactos)

```bash
cd ~/Projects/chatwoot/terranet/lab
./lab.sh init        # crea .env (chmod 600, gitignored) con secretos aleatorios de desarrollo
./lab.sh build       # primera vez ~15-20 min (compila gems nativas en Alpine); luego usa caché
./lab.sh up          # postgres/redis/mailpit/dns-sink -> db:chatwoot_prepare (crea, migra, siembra) -> rails/sidekiq/vite/gateway
./lab.sh health      # {"version":"4.19.1","queue_services":"ok","data_services":"ok"}
```

- Panel: <http://127.0.0.1:13000/app/login> · Mailpit: <http://127.0.0.1:18025>
- Usuario sintético del seed oficial `db/seeds.rb` (solo desarrollo local): `john@acme.inc` / `Password1!` (SuperAdmin + administrador de la cuenta "Acme Inc", con una conversación de ejemplo "Jane"). Es el dato público de upstream; no es de Terranet.
- `./lab.sh seed` no hace falta tras `up` (la primera preparación ya siembra); falla con *Email has already been taken* si se repite, lo cual es inofensivo.
- `./lab.sh bootstrap` (`pnpm install --frozen-lockfile`; es el único servicio con código de la app que tiene salida a Internet — `gateway` también está en `lab_edge` pero solo ejecuta `socat`) solo hace falta si cambia `package.json`/`pnpm-lock.yaml`; la imagen ya trae `node_modules`.

## 4. Operación diaria

| Comando | Qué hace |
|---|---|
| `./lab.sh ps` / `logs [servicio]` | estado / últimas 100 líneas |
| `./lab.sh down` | detiene (conserva datos) |
| `./lab.sh reset` | detiene y **borra volúmenes del lab** (DB, Redis, node_modules, caché) |
| `./lab.sh rails <tarea>` | `bundle exec rails <tarea>` dentro del contenedor |
| `./lab.sh test-db` | crea `chatwoot_test` (DB y Redis index 5 separados del desarrollo) |
| `./lab.sh rspec <rutas>` | RSpec en DB/Redis de test |
| `./lab.sh vitest <ruta>` | Vitest (`pnpm test`) |
| `./lab.sh dns-log` | consultas DNS registradas por el sumidero (nombres, sin payload) |

**`guard_tree`:** dentro del contenedor, `db:chatwoot_prepare`/migraciones ejecutan `annotate_rb` y re-vuelcan `db/schema.rb`, lo que reescribe ~28 archivos versionados (`app/models/**`, `enterprise/app/models/**`, `db/schema.rb`). `lab.sh` envuelve `up`, `seed` y `rails` en `guard_tree`, que restaura **solo** los archivos que estaban limpios antes y quedaron sucios durante el comando; nunca toca ediciones previas. (Descubierto en la primera ejecución: ocurrió y se revirtió con `git checkout` de esos archivos.)

## 5. Recuperación

| Síntoma | Acción |
|---|---|
| Rails no responde | `./lab.sh logs rails`; `docker compose restart rails sidekiq` |
| `Address already in use` al crear la red | otra red usa `172.29.250.0/24`; cambiar subred y `dns:` en `docker-compose.yml` |
| Puertos ocupados | cambiar `LAB_*_PORT` en `.env` (Vite debe quedar en 3036 salvo que se ajuste `config/vite.json`) |
| DB corrupta/sucia | `./lab.sh reset && ./lab.sh up` |
| Archivos del repo con `M` tras usar `rails` directo con `docker compose run` | `git status`; restaurar solo lo generado (`app/models/**`, `db/schema.rb`) |
| Rails/Sidekiq no arrancan por gems faltantes | `./lab.sh build` |

Notas: Rails sirve assets precompilados bajo `/vite-dev/assets` (auto-build) en lugar de HMR: suficiente para pruebas; el hot-reload completo no está validado (**pendiente**). El contenedor corre como root (como el compose oficial); `log/`, `tmp/` y `public/vite-dev` quedan root-owned pero ignorados por Git.

## 6. Resultados de las pruebas (FACT)

| Prueba | Resultado |
|---|---|
| `./lab.sh up` desde cero (tras `reset`) | OK en ~22 s con imagen en caché; árbol de Git limpio tras `guard_tree` |
| `GET /api` | `{"version":"4.19.1","queue_services":"ok","data_services":"ok"}` |
| Login API `POST /auth/sign_in` (seed) | 200 |
| Login por UI + dashboard + lista de conversaciones (navegador integrado) | OK; conversación sintética "Jane" visible |
| Sidekiq | procesa jobs programados (p. ej. `Internal::CheckRingingTimeoutsJob`, `ConversationMonitors::DispatchJob`) |
| SMTP → Mailpit | OK: 1 correo recibido (asignación de conversación) con remitente `lab@terranet.invalid` |
| RSpec (`spec/controllers/webhooks/whatsapp_controller_spec.rb`, `spec/models/account_spec.rb`) | **100 ejemplos, 0 fallos** |
| RSpec (+ `spec/lib/chatwoot_hub_spec.rb`, `spec/enterprise/lib/chatwoot_hub_spec.rb`) con `DISABLE_TELEMETRY=true` | 110 ejemplos, **2 fallos esperados** (los specs asumen telemetría activa); con la variable eliminada: 8/8 en `chatwoot_hub_spec` |
| Vitest `app/javascript/shared/helpers` | 22 archivos, **302 tests pasan** |
| Suite completa RSpec/Vitest, ESLint, RuboCop | **No ejecutadas** (pendiente; ver siguientes pasos) |
| Hot-reload de Vite (HMR) | no validado |

## 7. Variables del lab (resumen; plantilla en `terranet/lab/env.lab.example`)

Dev/sintéticas: `SECRET_KEY_BASE`, claves `ACTIVE_RECORD_ENCRYPTION_*`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD` (aleatorias por `lab.sh init`), `FRONTEND_URL=http://localhost:13000`, `SMTP_ADDRESS=mailpit`, `ACTIVE_STORAGE_SERVICE=local`, `ENABLE_ACCOUNT_SIGNUP=false`.
Privacidad bajo prueba: `DISABLE_TELEMETRY=true` (⚠ cualquier valor la activa), `ENABLE_PUSH_RELAY_SERVER=false`. Recomendado añadir al lab: `DISABLE_GRAVATAR=1`.
