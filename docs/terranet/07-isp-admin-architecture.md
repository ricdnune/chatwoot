# 07 — ADR: sección nativa "Terranet ISP" en Super Admin (M4.0 — diagnóstico, sin código)

Estado: **opción A APROBADA por el propietario solo para prototipo local (2026-10-27); implementada en M4.1, ver `12-isp-module-m4-1.md` (incluye las diferencias respecto a este ADR, §7)** · Fecha: 2026-10-27 · Base `v4.19.1`, edición Community (Camino B).
Alcance de esta iteración: inspección real del repositorio y de la documentación oficial vigente. **No se escribió código del módulo, no se usó ningún token real, no se llamó a WispHub ni a SmartOLT con credenciales.** (Se descargaron las páginas/especificaciones públicas de documentación.)
Convención: **FACT** (archivo/URL) · **INFERENCE** · **DECISION** · **UNVERIFIED**.

## 1. Contexto y objetivo
Un único ISP, una única instalación de Chatwoot. Super Admin debe poder (a) configurar los proveedores WispHub y SmartOLT con sus credenciales de forma segura, (b) probar la conexión en solo lectura, (c) gestionar el vínculo abonado ↔ contacto/conversación (modelo en `08-customer-360-identity-model.md`) y (d) auditar todo, sin depender de código Enterprise ni exponer secretos fuera del backend.

## 2. Hechos del repositorio (FACT)

| Tema | Hallazgo | Evidencia |
|---|---|---|
| Autenticación Super Admin | `SuperAdmin::ApplicationController < Administrate::ApplicationController` con `before_action :authenticate_super_admin!` (Devise, scope `super_admin`); inicio de sesión propio `/super_admin/sign_in` | `app/controllers/super_admin/application_controller.rb`, `config/routes.rb:777-780` |
| Qué es un Super Admin | `class SuperAdmin < User` (STI sobre `users.type = 'SuperAdmin'`); **el mismo registro puede ser agente de cuentas y Super Admin** | `app/models/super_admin.rb`; `db/seeds.rb:28` |
| Cómo se concede/revoca | En Super Admin → Users → editar, campo `type` = `SuperAdmin`/vacío (`Field::Select.with_options(collection: [nil, 'SuperAdmin'])`) | `app/dashboards/user_dashboard.rb:38` |
| Protección de login | `rack-attack`: 5 intentos/5 min por IP y 5/15 min por email en Super Admin | `config/initializers/rack_attack.rb:135-139` |
| Impersonación | auditada con `ImpersonationLogger` | `app/controllers/concerns/impersonation_logging.rb` |
| Rutas | todas bajo `namespace :super_admin` dentro de `devise_scope :super_admin`; "el orden de recursos afecta el orden del menú" | `config/routes.rb:780-826` |
| Menú | `SuperAdmin::NavigationHelper#primary_nav_items` construye el menú; `SETTINGS_GROUPS` y `settings_pages` listan páginas de ajustes (solo features con `config_key` y `enabled`) | `app/helpers/super_admin/navigation_helper.rb` |
| Patrón de formularios de configuración | `AppConfigsController#show/create` + vista `app_configs/show.html.erb`; campos `type: 'secret'` | `app/controllers/super_admin/app_configs_controller.rb`, `app/views/super_admin/app_configs/show.html.erb:34-47` |
| **⚠ Los secretos de integraciones viven en claro** | Las configs `secret` se guardan en `installation_configs.serialized_value` (YAML, **sin cifrar**) y el formulario **vuelve a incrustar el valor real** en el HTML (`password_field … value: @app_config[key]`) con botón de revelar | mismos archivos; `app/models/installation_config.rb:35` |
| Cifrado disponible | Rails 7.2 Active Record Encryption: `encrypts …` usado en `Channel::Email`, `Channel::Line`, `Channel::FacebookPage`, `Integrations::Hook` (`encrypts :access_token, deterministic: true if Chatwoot.encryption_configured?`), etc. Las claves llegan por `ACTIVE_RECORD_ENCRYPTION_*` (env, fuera de la DB) | `config/application.rb:75-78,100-108`, `app/models/**` |
| **⚠ El cifrado es opcional en upstream** | `Chatwoot.encryption_configured?` devuelve `false` si faltan las 3 variables y varios modelos **omiten silenciosamente** `encrypts` en ese caso | `config/application.rb:100-108`, `app/models/channel/whatsapp.rb:31` |
| Auditoría | La gema `audited` está en el `Gemfile` (MIT); los modelos de auditoría de Chatwoot (`Enterprise::Audit::*`, `audit_logs`) son **Enterprise** y no se usan | `Gemfile:186`; `enterprise/app/models/enterprise/audit*` |
| Colas | `config/sidekiq.yml` (colas fijas); jobs cron en `config/schedule.yml`; `max_retries: 3` | `config/sidekiq.yml` |
| HTTP seguro | `lib/safe_fetch/*` (MIT) resuelve DNS y rechaza redes privadas para descargas; pensado para archivos, aprovechable para su lógica de validación de destino | `lib/safe_fetch/private_network_request.rb` |
| Modelo de datos de conversación | `Contact` (`account_id`, `phone_number` validado E.164 `\A\+[1-9]\d{1,14}\z`, `identifier` único por cuenta, `custom_attributes`), `ContactInbox`, `Conversation` (`account_id`, `display_id` único por cuenta) | `app/models/contact.rb:50-65`, `conversation.rb` |
| Panel de conversación | `ContactPanel.vue` es una lista **arrastrable** de secciones tipo acordeón (`conversationSidebarItemsOrder`) con precedentes por integración (Shopify, Stripe, Linear) → punto natural para "Terranet · Cliente ISP" | `app/javascript/dashboard/routes/dashboard/conversation/ContactPanel.vue` |

## 3. Documentación oficial consultada (2026-10-27)

### WispHub — `https://wisphub.net/api-docs/` (spec: `https://wisphub.net/static/yaml/api/api-main.yaml`, v1.2.0)
- **FACT** Bases: producción `https://api.wisphub.net/api/`, pruebas **`https://sandbox-api.wisphub.net/api/`**; credenciales distintas por entorno.
- **FACT** Autenticación: cabecera `Authorization: Api-Key <clave>`; la clave se genera **por miembro del personal** en la plataforma y **cada recurso exige un permiso** del usuario (p. ej. "Lista de Clientes"). ⇒ Crear un usuario de personal dedicado con **solo permisos de lectura** (principio de mínimo privilegio).
- **FACT** Paginación `limit`/`offset` → `{count,next,previous,results}`. Errores 400/401/403/404/422/500 (la tabla del doc).
- **FACT (solo lectura, candidatos del MVP):** `GET /clientes/` (lista), `GET /clientes/{id_servicio}/`, `GET /clientes/{id_servicio}/saldo/`, `GET /clientes/{id_servicio}/perfil/`, `GET /facturas/`, `GET /facturas/{id_factura}/`, `GET /tickets/`, `GET /tickets/{id_ticket}/`, catálogos (`/plan-internet/`, `/zonas/`, `/router/`).
- **FACT (escritura — fuera del MVP):** `PUT /clientes/{id_servicio}/`, `/clientes/{accion}/` (activar/desactivar), `/clientes/agregar-cliente/…`, `/clientes/eliminar-clientes/`, `/facturas/{id}/registrar-pago/`, `/facturas/eliminar-facturas/`, `/gastos/*`, `/plan-internet/*/agregar/`…
- **UNVERIFIED** `GET /clientes/{id_servicio}/ping/`: el spec la lista; no se ha leído su semántica (puede ejecutar una acción en el router) → excluida hasta leerla.
- **UNVERIFIED** límites de tasa de WispHub: la documentación leída **no los declara**; configurar con valores conservadores y medir en sandbox.
- **FACT — campos del cliente** (`components/Clientes.yaml`): `id_servicio, usuario, nombre, email, cedula, direccion, localidad, ciudad, telefono, saldo, estado, estado_facturas, plan_internet, zona, router, sn_onu, mac_cpe, ip, fecha_instalacion, fecha_corte…` **y secretos en claro:** `password_servicio, password_cpe, password_router_wifi, password_ssid_router_wifi, usuario_router_wifi`. ⇒ El normalizador es una **lista blanca**; todo campo `password*`/`usuario_*` se descarta en el adaptador y nunca se persiste ni se loguea.

### SmartOLT — `https://api.smartolt.com/` (OpenAPI 3.0.3: `https://www.smartolt.com/openapi.json`, 120 rutas: 38 `GET`, 82 `POST`)
- **FACT** Base `https://{subdominio}.smartolt.com/api/…`; autenticación `X-Token` (apiKey en cabecera).
- **FACT** Respuesta con `status` (booleano) y `error`/`error_code`.
- **FACT** Límites por defecto: **1 000 llamadas/h**, **5 000/h** asíncronas, **15/s** (superarlo bloquea todo 10 s); **429 + `Retry-After`** con cuerpo `response_code: rate_limit_exceeded`; algunos endpoints tienen límite propio.
- **FACT** Octubre 2026: **eventos en tiempo real (SSE o webhook)** para cambios de estado/señal/caídas PON; se pide **no sondear** `get_all_onus_statuses/signals`. Endpoint `GET /api/onu/get_event_stream`.
- **FACT** `GET /api/onu/get_onu_signal/{id}` y `get_onus_details_by_sn/{sn}` están **restringidos por la propia doc**: "no usar en scripts de sondeo, bucles de monitoreo ni recolección masiva; solo para depurar una ONU concreta". ⇒ La señal óptica se pide **bajo demanda de un agente** (botón), con caché y límite por ONU; el estado continuo debe venir de **eventos**.
- **FACT (lectura candidata del MVP):** `get_onu_details/{unique_external_id}` (clave estable **`unique_external_id`**), `get_onu_status/{id}`, `get_onu_status_history/{id}` (hasta 365 días), `get_onu_signal/{id}`, `get_onus_details_by_sn/{sn}`, `search_by_mac`, `get_olts`, `get_zones`, `get_outage_pons/{olt_id}`.
- **FACT ⚠ la respuesta de detalle de ONU incluye `username` y `password`** (credenciales) además de IPs de gestión/WAN. ⇒ Lista blanca y descarte, igual que WispHub. `get_running_config` y `get_onu_router_hosts` quedan **excluidos** del MVP (pueden contener datos sensibles del cliente).
- **FACT (escritura — fuera del MVP):** los 82 `POST` (autorizar/eliminar/reiniciar ONU, cambiar perfil, activar/desactivar, CATV…).

## 4. Opciones evaluadas

| Criterio | **A. Página nativa en Super Admin (módulo `Terranet::Isp`)** | B. Account Settings (UI de la cuenta) | C. Microservicio externo |
|---|---|---|---|
| Quién configura | Solo Super Admin (control real de servidor) | Administradores de cuenta (rol más amplio) ✗ | Consola propia + auth propia |
| Secretos | Cifrados en la misma DB con claves fuera de la DB; nunca llegan al navegador | Idem, pero visibles a más usuarios | Almacén propio; **nuevo** punto de compromiso y de HA |
| Coste operativo | Cero procesos nuevos (Rails + Sidekiq existentes) | Cero | Otro servicio, despliegue, versionado, observabilidad, auth entre servicios |
| Latencia en conversación | Misma app, caché Redis | Idem | Salto de red extra |
| Actualización upstream | Archivos nuevos + 1–2 ganchos T3 mínimos | Toca vistas/rutas de cuenta (más superficie upstream) ✗ | Desacoplado del upstream ✓ |
| Dependencias Enterprise | Ninguna | Ninguna | Ninguna |
| Aislamiento por Account | `account_id` en cada tabla/consulta | Natural | Hay que replicarlo |
| Encaja con "un ISP, una instalación" | ✓ | ✓ | Sobredimensionado |

**DECISION propuesta: A**, con datos y consultas siempre acotados por `account_id` (aunque haya una sola cuenta) para no hipotecar el aislamiento. Se descarta B porque el rol Administrador de cuenta **no** debe ver ni cambiar credenciales de proveedores ISP; se descarta C por coste operativo sin beneficio medible (si más adelante hiciera falta, la capa de adaptadores `Terranet::Isp::Providers::*` se puede mover detrás de una API sin cambiar la UI).

## 5. Arquitectura propuesta

### 5.1 Componentes (todos **T2**: archivos nuevos bajo namespace `Terranet::Isp`)
```
app/controllers/terranet/isp/admin/{base,overview,providers,connection_checks,bindings,audit_events}_controller.rb
   Base < SuperAdmin::ApplicationController        # hereda authenticate_super_admin!
app/models/terranet/isp/{provider_credential,connection_check,audit_event,customer_binding,...}.rb
app/services/terranet/isp/providers/{base,wisphub,smartolt,fake}.rb   # interfaz común, normalizadores en lista blanca
app/services/terranet/isp/{secure_http,rate_limiter,circuit_breaker,connection_tester}.rb
app/jobs/terranet/isp/*.rb  (queue_as :low en el MVP; cola propia solo con aprobación de editar sidekiq.yml)
app/views/terranet/isp/admin/**  (design system de Super Admin: ui(:input), sección/section, etc.)
config/initializers/terranet_isp.rb    # Rails.application.routes.prepend { namespace :super_admin … } (sin editar routes.rb)
lib/terranet/isp/…                     # constantes, validadores
```
Ganchos upstream **mínimos (T3)**: (1) una entrada de menú — preferible un módulo `prepend` sobre `SuperAdmin::NavigationHelper#primary_nav_items` (T2); si el prepend no es viable por cómo se compone el menú, un parche de ≤5 líneas; (2) ninguna otra edición de archivos upstream. Sin dependencia de `enterprise/` ni de `ChatwootApp.enterprise?`.

### 5.2 Rutas (bajo `/super_admin/terranet_isp`)
`GET /` (General) · `GET|PATCH /providers/:provider` (formulario) · `POST /providers/:provider/test` (Probar conexión) · `POST /providers/:provider/rotate` · `GET /bindings`, `POST /bindings/:id/confirm|reject|revoke` · `GET /audit`. Todas heredan `authenticate_super_admin!` y CSRF; ninguna acepta `account_id`/rol desde parámetros para decidir permisos.

### 5.3 Modelo de datos mínimo (M4.1) — migraciones reversibles, índices explícitos, **sin FK de BD** (política del repo)
```
terranet_isp_provider_credentials
  id, account_id (not null, index), provider (wisphub|smartolt), environment (sandbox|production),
  base_url_host (host validado, p. ej. api.wisphub.net / <sub>.smartolt.com), secret (ENCRYPTED, non-deterministic),
  secret_hint (últimos 4), status (not_configured|connected|error|disabled), last_checked_at, last_latency_ms,
  last_error_code, rotated_at, rotated_by_id, created_by_id, timestamps
  UNIQUE (account_id, provider, environment)
terranet_isp_connection_checks   (historial acotado: id, credential_id, account_id, actor_id, ok, http_status, latency_ms, error_code, request_id, created_at)
terranet_isp_audit_events        (account_id, actor_id, action, subject_type/id, outcome, request_id, ip, metadata jsonb SIN secretos ni PII, created_at; solo INSERT)
```
(`customer_binding` y cachés de servicio/ONU: ver `08`.)

### 5.4 Secretos — reglas obligatorias
1. **Cifrado autenticado en columna** con Active Record Encryption (`encrypts :secret`, **no determinista**), claves `ACTIVE_RECORD_ENCRYPTION_*` **fuera de la DB y de los backups** (secret store / archivo con permisos), **idénticas en ambos nodos**; soportar rotación con `previous` keys.
2. **Fail-closed:** si `Chatwoot.encryption_configured?` es falso, el módulo **no guarda ni usa** credenciales (error visible en "General"); a diferencia de los modelos upstream, jamás se degrada a texto claro. Test: guardar sin claves ⇒ excepción.
3. **No usar `installation_configs`** ni el patrón `type: 'secret'` de `app_configs` (que reincrusta el secreto en el HTML).
4. **Nunca de vuelta al cliente:** el formulario muestra `••••••••` + `secret_hint` + botones *Reemplazar/Rotar*; el campo de entrada llega vacío. Ninguna respuesta JSON/HTML, flash, log, evento de auditoría ni `inspect` contiene el valor (AR añade atributos cifrados a `filter_attributes`; además se filtra `:secret`, ya incluido en `filter_parameters`).
5. **No en frontend/localStorage/URL/atributos legibles**; el navegador **nunca** llama a WispHub/SmartOLT (todo pasa por el backend).
6. Rotación: nuevo secreto → prueba de lectura → si pasa, reemplaza atómicamente; se registra actor, fecha y resultado (sin valores).
7. Backups/HA: sin las claves de cifrado los secretos son irrecuperables; documentar custodia (ver `05`).

### 5.5 Protección SSRF y red
- **Allowlist estructural, no URL libre:** WispHub = host fijo según entorno (`api.wisphub.net` / `sandbox-api.wisphub.net`, esquema `https`, ruta base `/api/`). SmartOLT = `https://{subdominio}.smartolt.com`, con `subdominio` validado por regex `\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z` (**sin puntos**, sin puertos, sin userinfo).
- La URL se **construye** en el servidor a partir de esos componentes; el usuario nunca envía una URL.
- HTTPS obligatorio, **sin seguir redirecciones**, timeouts acotados (conexión ≈3 s, lectura ≈8 s), tamaño máximo de respuesta, `Content-Type` JSON, TLS con verificación; validar la IP resuelta contra redes privadas/loopback/link-local (reutilizando la lógica de `SafeFetch`).
- **Rate limit y respeto de 429:** token bucket en Redis por credencial (SmartOLT: valores por defecto 15/s y 1 000/h **configurables**, nunca codificados como verdad); ante `429` se obedece `Retry-After`; backoff exponencial con jitter solo en `GET` idempotentes; **circuit breaker** por proveedor (estado visible).
- Allowlist de egress a nivel de red (ver `03` §11): los FQDN de WispHub y `*.smartolt.com` se habilitan **solo en staging con autorización**.

### 5.6 Permisos (RBAC)
- Solo `SuperAdmin` real (Devise, `type = 'SuperAdmin'` en servidor). **No** se admite un rol enviado por el navegador ni elevación por parámetro; no se publican endpoints de autoelevación.
- Los Administradores y agentes de cuenta **no** acceden a `/super_admin/*` (Devise scope aparte) — a probar con specs: sin sesión, agente, administrador de cuenta, y Super Admin de otra instalación.
- Recomendado: **MFA** para las cuentas Super Admin (el código soporta MFA cuando el cifrado está configurado: `Chatwoot.mfa_enabled?`), y límite de intentos ya existente (rack-attack).
- Panel de conversación (agentes): solo recibe datos **normalizados y enmascarados según rol** vía API propia con Pundit (`08`); nunca ve credenciales.

### 5.7 Procedimiento seguro para conceder/revocar Super Admin (para el propietario)
1. **Conceder:** un Super Admin existente entra a `/super_admin/users`, edita al usuario destino y fija **Type = SuperAdmin** (mecanismo legítimo `UserDashboard`). Queda en el historial del navegador de quien lo hace y se recomienda registrar un `Terranet::Isp::AuditEvent` (hook en el módulo, M4.1).
2. **Arranque inicial** (si no hubiera ninguno): consola del servidor con la identidad leída de una variable de entorno **que no se versiona** — p. ej. `TERRANET_ADMIN_EMAIL=… rails runner 'User.find_by!(email: ENV.fetch("TERRANET_ADMIN_EMAIL")).update!(type: "SuperAdmin")'`. **Ninguna identidad queda escrita en el repositorio**; no se crean contraseñas por defecto.
3. Exigir contraseña fuerte y **activar MFA** para esa cuenta antes de usarla.
4. **Revocar:** editar al usuario y dejar Type vacío; opcionalmente invalidar sus sesiones.
5. Alcance: un Super Admin administra **toda la consola Community** y los módulos Terranet; **no** habilita funciones propietarias de Chatwoot (la consola muestra `Plan: Community`).
6. **Demostración en el laboratorio (2026-10-27, usuario sintético `ops-demo@example.invalid`, ya eliminado):** (1) usuario agente normal → `type = nil`; (2) inicio de sesión en `/super_admin/sign_in` **antes** de la concesión → rechazado (302 de vuelta a sign_in); (3) concesión con la variable de entorno `TERRANET_ADMIN_EMAIL` y `rails runner` → `type = "SuperAdmin"`; (4) el mismo inicio de sesión → 302 a `/super_admin` y `GET /super_admin` = 200; (5) revocación (`type = nil`) → la sesión anterior deja de valer de inmediato (302 a sign_in). El procedimiento no escribe ninguna identidad en el repositorio.

## 6. Interfaz propuesta — Super Admin → **Terranet ISP** (pestañas)
- **General:** estado del módulo, versión, **verificación de cifrado configurado** (rojo si no), estado del modo de privacidad (solo lectura), última sincronización, errores recientes, contadores.
- **Proveedores › WispHub:** selector de entorno (sandbox/producción), campo *Api-Key* (password, vacío), máscara + `secret_hint`, estado (No configurado/Conectado/Error), **Probar conexión** (llamada de solo lectura: `GET /clientes/?limit=1`, **UNVERIFIED** hasta validarlo en sandbox con clave autorizada), latencia, último test, fecha de rotación, actor; **Rotar**.
- **Proveedores › SmartOLT:** campo *subdominio* (validado), *X-Token* (password), **Probar conexión** (`GET /api/system/get_olts`), alcance y límites (valores configurables), última sincronización, rotación.
- **Identidad y matching:** tabla de vínculos y conflictos, búsqueda, vincular/desvincular manual con motivo, historial (ver `08`).
- **Sincronización:** solo lectura; TTL/freshness por bloque, cola, errores, contadores; **sin** botón de sincronización completa sin cotas.
- **Auditoría y diagnósticos:** actor/fecha/resultado de pruebas y rotaciones; nunca tokens ni cargas útiles sensibles.
- **Fuera de alcance del MVP (sin botones):** activar/desactivar servicio, reiniciar ONU, registrar pago, editar cliente, crear facturas, cualquier `POST/PUT/DELETE` de los proveedores.

## 7. Compatibilidad y análisis de `enterprise/` (solo lectura, sin reutilización)
`enterprise/` aporta Captain, SLA, audit logs, roles personalizados, SAML, branding personalizable, campañas, etc. (`enterprise/config/premium_features.yml`). **Este módulo no lee, copia ni prepende nada de `enterprise/`**; necesidades equivalentes (auditoría, RBAC) se resuelven con código propio MIT (tabla `audit_events`, Devise/SuperAdmin). Riesgo de upgrade: si upstream cambia `SuperAdmin::NavigationHelper`/`ApplicationController`, solo se re-validan los dos ganchos; los tests de rutas/permisos (§9) lo detectan.

## 8. Riesgos y mitigaciones
| Riesgo | Mitigación |
|---|---|
| Claves de cifrado ausentes o distintas entre nodos | fail-closed + comprobación visible en "General" + procedimiento de custodia (`05`) |
| Fuga de secreto por logs/Sentry/errores | no se loguea ni se serializa el valor; errores sanitizados (código + mensaje propio, no cuerpo del proveedor); `filter_attributes` |
| Cuenta Super Admin comprometida | MFA, rack-attack, auditoría de rotaciones; el UI no revela el secreto (solo reemplazarlo) |
| Exceso de llamadas a SmartOLT (límite 1 000/h) | cuota por credencial, caché, uso de eventos SSE/webhook, señal bajo demanda |
| Datos sensibles en respuestas (passwords, cédula) | normalizadores con lista blanca + test que falla si aparece un campo no listado |
| Cambio de API de proveedores | contratos/fixtures generados desde el OpenAPI vigente + tests de contrato; `UNVERIFIED` se marca |

## 9. Plan de pruebas (M4.1)
Specs: cifrado obligatorio (sin claves ⇒ error), el secreto nunca aparece en HTML/JSON/logs/auditoría, máscara, rotación atómica, validación de host SmartOLT y rechazo de URLs arbitrarias/redirects/IPs privadas, `429 Retry-After`, breaker, lista blanca de campos (password/usuario descartados), matriz de permisos (sin sesión/agente/administrador/Super Admin), IDOR entre cuentas, CSRF, y **cero llamadas de red reales** (WebMock + servidor mock local `terranet/lab/mocks/isp`). Vitest/ESLint para el panel. `audit-egress` debe seguir en PASS.

## 10. Fases y criterios de aceptación
| Fase | Entrega | Aceptación |
|---|---|---|
| M4.0 (esta) | ADR + hechos + diseño | revisión del propietario |
| **M4.1** (tras aprobar) | esqueleto navegable en Super Admin con pestañas y estados simulados, adaptadores `Fake`+mock HTTP, tablas cifradas, "Probar conexión" solo contra mock | todos los specs del §9 verdes; el secreto no sale del backend (test de inspección de respuestas); menú visible solo para Super Admin; sin llamadas reales; árbol limpio |
| Staging (aparte) | credenciales inyectadas de forma segura, sandbox WispHub, FQDN permitidos | autorización escrita; claves de solo lectura; logs redactados |
| M5+ | vínculos, panel 360, eventos SmartOLT | ver `08` |

## 11. Decisiones que necesito del propietario
1. Aprobar la opción **A** y el uso de la tabla propia de auditoría (en vez de `audited`).
2. Confirmar que se generarán **claves de cifrado de producción** (`ACTIVE_RECORD_ENCRYPTION_*`) y quién las custodia; sin ellas el módulo no se activa.
3. Un usuario de personal WispHub **dedicado de solo lectura** y un token SmartOLT de **lectura** (cuando haya autorización de staging; **no** enviarlos por chat).
4. Política de retención de auditoría y de datos cacheados (normativa ecuatoriana aplicable: pendiente de confirmar con el responsable legal).
