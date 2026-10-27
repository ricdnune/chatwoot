# 03 — Auditoría de privacidad y egress (M2, parte 1: hallazgos y pruebas)

Base: `terranet/main` = `v4.19.1`. Laboratorio: `terranet/lab/` (ver `01-local-development.md`). Convención: **FACT** (archivo/commit o ejecución en el lab) · **INFERENCE** · **DECISION** · **UNVERIFIED**.

**Estado de M2: NO terminado.** Se auditó el código y se obtuvo evidencia de runtime inicial; faltan el parche/configuración final, las pruebas de regresión automatizadas y la política de egress en red. No se ha tocado producción.

## 1. Resumen ejecutivo

1. **FACT (runtime):** `DISABLE_TELEMETRY=true` **no** logra "cero tráfico a Chatwoot". Elimina los contadores de uso (`accounts_count`, `users_count`, `conversations_count`, …) y los eventos (`emit_event`), pero el job diario de versión **sigue enviando** a `https://hub.2.chatwoot.com/ping`: `installation_identifier`, `installation_version`, `installation_host`, `installation_env`, `edition` (ver §3, prueba A vs B).
2. **FACT (código):** la variable se evalúa como `ENV['DISABLE_TELEMETRY']` (`lib/chatwoot_hub.rb:88,122`): **cualquier valor no nulo —incluso `false` o cadena vacía— la activa**. Para "apagar" la protección hay que no definir la variable. (Trampa operativa; documentar.)
3. **FACT (código):** en la edición con overlay Enterprise, el mismo ping diario **recibe el plan licenciado** y lo escribe en `installation_configs` (`INSTALLATION_PRICING_PLAN`, `…_QUANTITY`) más tres claves de widget de soporte de Chatwoot (`CHATWOOT_SUPPORT_*`), y luego reconcilia features premium (`enterprise/app/jobs/enterprise/internal/check_new_versions_job.rb`). **Bloquear `hub.2.chatwoot.com` en un despliegue con licencia Enterprise rompe la sincronización del plan.** Zero-egress y Enterprise licenciado son incompatibles; hay que decidir (ver §7).
4. **FACT (runtime frontend):** login + dashboard + lista de conversaciones en el lab generaron **solo** peticiones a `127.0.0.1:13000` (ninguna a terceros ni a Chatwoot). Es una muestra, no una prueba exhaustiva (ver §6).
5. **FACT (código):** el panel de changelog del sidebar (que consulta `hub.2.chatwoot.com/changelogs` desde el navegador del agente) solo se monta si `isOnChatwootCloud` (`components-next/sidebar/Sidebar.vue:1089-1102`): no se renderiza en self-hosted. Sin embargo, `v3/api/testimonials.js` consulta `testimonials.cdn.chatwoot.com` en la pantalla de **signup** (`Testimonials/Index.vue`); con `ENABLE_ACCOUNT_SIGNUP=false` no debería cargarse (**UNVERIFIED** en runtime).

## 2. Mecanismos de salida hacia Chatwoot-gestionado (FACT, código)

| # | Mecanismo | Ruta / línea | Destino | Datos | Control |
|---|---|---|---|---|---|
| 1 | Ping diario de versión | `app/jobs/internal/check_new_versions_job.rb` (solo `Rails.env.production?`), programado desde `Internal::TriggerDailyScheduledItemsJob` (cron diario, minuto estable por instalación) → `ChatwootHub.sync_with_hub` | `POST hub.2.chatwoot.com/ping` | `installation_identifier` (UUID persistente), versión, host (`FRONTEND_URL`), `INSTALLATION_ENV`, `CW_EDITION` **+ contadores** salvo `DISABLE_TELEMETRY` | Contadores: `DISABLE_TELEMETRY`. **Ping base: sin interruptor**; requiere parche T3 o bloqueo de red |
| 2 | Eventos | `ChatwootHub.emit_event` (`lib/chatwoot_hub.rb:121`) | `POST …/events` | evento + identificador | `DISABLE_TELEMETRY` (en v4.19.1 **no hay llamadores** en `app/`, `lib/`, `enterprise/`, `config/`) |
| 3 | Registro de instancia | `Installation::OnboardingController#finish_onboarding` → `register_instance` | `POST …/instances` | **nombre de empresa, nombre y email del dueño**, identificador | Solo si en el onboarding se marca `subscribe_to_updates`; **no marcarlo**. Sin variable de control |
| 4 | Relay de push móvil | `Notification::PushNotificationService#send_push_via_chatwoot_hub` → `ChatwootHub.send_push` | `POST …/send_push` | token FCM + título/URL de la notificación + identificador | `ENABLE_PUSH_RELAY_SERVER=false` (gate en `push_notification_service.rb:114-116` y `push_test_service.rb:90`); además se omite si hay `FIREBASE_PROJECT_ID`+`FIREBASE_CREDENTIALS` propios |
| 5 | Plan/licencia y soporte (Enterprise) | `Enterprise::Internal::CheckNewVersionsJob#update_plan_info` | respuesta del ping | **entrada**, escribe config local | ver hallazgo 3 |
| 6 | Widget de soporte en Super Admin | `app/views/super_admin/application/_javascript.html.erb:23-50` | `CHATWOOT_SUPPORT_SCRIPT_URL` (vacío por defecto; lo llena la respuesta del ping en #5) | si está configurado: `setUser(installation_identifier, {email, name})` del **primer SuperAdmin** | No poblar (`CHATWOOT_SUPPORT_*` vacíos); evitar #5 o limpiar esas claves. **UNVERIFIED** qué respuestas del hub las llenan |
| 7 | Changelog (navegador) | `shared/constants/links.js:11` + `SidebarChangelogCard.vue` | `GET hub.2.chatwoot.com/changelogs` | IP/UA del agente | Inactivo en self-hosted (hallazgo 5); verificar en runtime con DevTools |
| 8 | Testimonios (navegador) | `dashboard/constants/globals.js:44` | `GET testimonials.cdn.chatwoot.com/testimonial-content.json` | IP/UA | Solo pantalla de signup |
| 9 | Enlaces de ayuda/estado/blog | `globals.js:41-47,82` (`www.chatwoot.com/docs`, `status.chatwoot.com/…`) | solo al hacer clic | — | Son enlaces, no tráfico automático; revisar en branding |
| 10 | Chequeo manual de versión | `app/controllers/super_admin/settings_controller.rb:5` → `CheckNewVersionsJob.perform_now` | hub (solo producción) | igual que #1 | Acción manual del superadmin |

## 3. Pruebas de runtime realizadas (repetibles)

Script: `terranet/lab/scripts/egress_probe.rb` (reemplaza `RestClient.post` por un registrador; imprime **destino y nombres de campos, nunca valores**). Ejecución: `terranet/lab/lab.sh rails runner terranet/lab/scripts/egress_probe.rb`.

**A) Lab con `DISABLE_TELEMETRY=true`, `ENABLE_PUSH_RELAY_SERVER=false`**
```
sync_with_hub  -> POST https://hub.2.chatwoot.com/ping
                  keys: edition, installation_env, installation_host, installation_identifier, installation_version
emit_event     -> (no outbound call)
register_instance -> POST https://hub.2.chatwoot.com/instances  (keys incl. company_name, owner_name, owner_email)
send_push (llamada directa) -> POST https://hub.2.chatwoot.com/send_push
```
**B) Control, sin `DISABLE_TELEMETRY` (comportamiento upstream)**
```
sync_with_hub  -> POST …/ping   keys: A + accounts_count, users_count, inboxes_count, conversations_count,
                                incoming_messages_count, outgoing_messages_count, additional_information
emit_event     -> POST …/events
```
Lectura: la variable funciona para #2 y para los contadores de #1 (**CONFIRMADO**), no para el ping base (#1), ni #3. En A, `send_push` se llamó **directamente**; el gate de `ENABLE_PUSH_RELAY_SERVER` vive en el servicio llamador, por lo que esta prueba no demuestra el gate (pendiente: prueba de `Notification::PushNotificationService` con suscripción FCM sintética).

**Specs upstream:** `spec/lib/chatwoot_hub_spec.rb` — 8 ejemplos. Con `DISABLE_TELEMETRY=true` en el entorno **2 fallan** (`sync_with_hub` y `emit_event` esperan payload con contadores/eventos); con la variable eliminada **8/8 pasan**. Consistente con lo anterior (el spec no aísla la variable; no es un defecto del producto).

**Aislamiento del lab (prueba):** desde el contenedor `rails` (red interna sin ruta externa): `getent hosts hub.2.chatwoot.com` → `192.0.2.1` (sumidero); `wget https://hub.2.chatwoot.com` → fallo; `wget http://1.1.1.1` → *Network unreachable*. El contenedor `dns-sink` registra cada consulta (`lab.sh dns-log`).

**Frontend (navegador del panel integrado, login `john@acme.inc` sintético del seed):** ~190 peticiones, **todas** a `127.0.0.1:13000` (assets Vite, API, `/brand-assets/*`, `mini-profiler` solo en desarrollo). Sin Gravatar, sin fuentes externas, sin `hub.2.chatwoot.com`, sin analytics.

## 4. Conexiones NO-Chatwoot que conviene conocer (FACT salvo indicación)

| Destino | Origen | Condición |
|---|---|---|
| `www.gravatar.com` | `Avatar::AvatarFromGravatarJob` envía el **MD5 del email** del contacto/agente | Activo por defecto; se desactiva con `DISABLE_GRAVATAR` (cualquier valor no vacío). **Recomendado: activar** (fuga de hashes de email de abonados a un tercero) |
| `www.google.com/s2/favicons` | `Avatar::AvatarFromFaviconJob` (`app/jobs/avatar/avatar_from_favicon_job.rb:8`) envía el **dominio de la empresa** del contacto al crear/actualizar una `Company`. **Observado en runtime** en el lab (consulta DNS `www.google.com` tras el seed) | Sin interruptor conocido; **UNVERIFIED** si `DISABLE_GRAVATAR` lo cubre (no lo parece). Bloquear por FQDN o parche T3 |
| `www.gravatar.com` (runtime) | Observado en el lab: 2 consultas DNS tras el seed sintético | confirma la fila anterior |
| `stun.l.google.com:19302` | `enterprise/app/models/call.rb:45` (STUN por defecto para llamadas de voz, **Enterprise**) | Solo con funciones de llamadas; STUN sin payload de contenido, pero revela IP; evaluar si se usan llamadas |
| Sentry / Datadog / Elastic APM / New Relic / Scout | `config/application.rb`, `config/initializers/sentry.rb` | Solo si se definen `SENTRY_DSN`, `DD_TRACE_AGENT_URL`, `ELASTIC_APM_SECRET_TOKEN`, `SCOUT_KEY`, … **No definirlos**; `send_default_pii = true` salvo `DISABLE_SENTRY_PII` |
| Amplitude | `vueapp.html.erb:72-75` | Solo con `CLOUD_ANALYTICS_TOKEN` (vacío por defecto) |
| Analítica del Help Center (GA4, GTM, Hotjar, Plausible, Amplitude, Clarity, Meta Pixel) | `app/views/layouts/_portal_analytics.html.erb` | Solo si un admin configura los IDs en el portal; **auditar/bloquear por política** |
| OpenAI / OpenRouter / Firecrawl (Captain) | `config/initializers/ai_agents.rb`, `CAPTAIN_*` | Solo con claves; además Captain es **Enterprise** (ver licencias) |
| Meta (WhatsApp Cloud/Graph), SMTP, R2 | canales/config | **Necesarios**; permitir por FQDN |

## 5. Push móvil (decisión funcional, `ENABLE_PUSH_RELAY_SERVER`)

- **FACT:** `PushNotificationService#perform` hace por suscripción: `send_browser_push` (Web Push/VAPID propio), `send_fcm_push` (solo con Firebase propio) y `send_push_via_chatwoot_hub` (relay).
- **INFERENCE:** las apps móviles oficiales de Chatwoot dependen del relay porque su proyecto Firebase es de Chatwoot; con `ENABLE_PUSH_RELAY_SERVER=false` y sin infraestructura propia **dejan de llegar las notificaciones push a las apps móviles oficiales**. Las notificaciones de navegador (Web Push) no dependen del relay (**UNVERIFIED** en runtime).
- **DECISION propuesta:** `ENABLE_PUSH_RELAY_SERVER=false`; si Terranet necesita push móvil, evaluar app móvil propia + Firebase propio (alcance aparte) o aceptar solo web push. Registrar la decisión con el operador.

## 6. Pendientes de M2 (no hechos)

1. **Ping diario base (hallazgo 1/3):** decidir entre (a) bloqueo de red del FQDN (rompe sync de plan Enterprise, ver §7) o (b) parche T3 mínimo en `Internal::CheckNewVersionsJob` (`lib/`/`app/` MIT) que no llame al hub cuando una variable propia esté definida; **no tocar `enterprise/`**.
2. Comprobar en runtime que, con el ping bloqueado/ausente, el job no deja errores ruidosos (`ExceptionList::REST_CLIENT_EXCEPTIONS` vs. `SocketError`) — **UNVERIFIED**.
3. Probar `PushNotificationService` con suscripción FCM sintética y `ENABLE_PUSH_RELAY_SERVER=false`.
4. Cobertura de frontend más amplia con DevTools (conversación abierta, ajustes, Help Center, widget, signup, Super Admin con `CHATWOOT_SUPPORT_*` vacío) y con `RAILS_ENV=production` (el job del ping solo corre así).
5. Verificar que `mini-profiler` y herramientas de desarrollo **no** existan en producción.
6. Política de egress por FQDN (proxy o `dns-sink` en producción) y prueba de no-egreso automatizable en CI (job que arranque el lab y falle si `dns-log` contiene `chatwoot.com` salvo lista permitida).
7. Tests de regresión (RSpec) del parche T3 cuando se defina.
8. Revisar de nuevo en cada upgrade: nuevos llamadores de `ChatwootHub`, nuevas constantes con URLs externas.

## 6.1 Tabla de destinos (estado actual)

| Destino | Estado propuesto | Motivo |
|---|---|---|
| `hub.2.chatwoot.com` (`/ping`, `/instances`, `/send_push`, `/events`, `/changelogs`, `/billing`) | **Bloquear** (condicional a decisión §7) | telemetría/relay/licencia |
| `testimonials.cdn.chatwoot.com` | **Bloquear** | solo signup |
| `www.chatwoot.com`, `status.chatwoot.com`, `chatwoot.help` | Permitir solo como **enlaces manuales** del navegador (sin tráfico automático) | docs/estado |
| `github.com` | **Permitir solo en herramientas de desarrollo/release** (no runtime) | fetch upstream |
| `www.gravatar.com` | **Bloquear** (+ `DISABLE_GRAVATAR=1`) | fuga de hash de email |
| `www.google.com` (`/s2/favicons`) | **Bloquear** (o parche T3) | fuga de dominios de empresas de contactos |
| `stun.l.google.com` | **Condicional** (solo si se usan llamadas Enterprise) | revela IP; no usado en MVP |
| `graph.facebook.com` / dominios Meta WhatsApp | **Permitir** | canal oficial |
| `*.r2.cloudflarestorage.com` / endpoint R2 del bucket Terranet | **Permitir** (bucket propio) | adjuntos |
| SMTP de Terranet | **Permitir** | correo |
| WispHub / SmartOLT (FQDN reales) | **No verificado** — añadir cuando exista autorización | M5/M6 |
| Sentry/APM/analítica de terceros | **Bloquear** salvo decisión explícita | PII |
| DNS/NTP | **Permitir** | infraestructura |

## 7. ⚖ Decisión humana requerida: licencia vs. zero-egress

- **Opción A (Enterprise con suscripción):** el ping diario a `hub.2.chatwoot.com` es parte del mecanismo de plan/licencia; mantenerlo permitido (solo ese FQDN, solo ese job) y minimizar datos con `DISABLE_TELEMETRY=true`. "Zero Chatwoot-owned telemetry" queda **parcialmente** cumplido: persiste identificador/versión/host.
- **Opción B (edición solo MIT):** `DISABLE_ENTERPRISE=true` + parche T3 mínimo que omite el ping base ⇒ cero egress a Chatwoot en runtime. Se pierden las funciones Enterprise. Requiere confirmar con asesoría legal el uso de la edición MIT con el repositorio que contiene `enterprise/`.
- **No se permite** simular respuestas del hub, escribir `INSTALLATION_PRICING_PLAN` a mano ni alterar gates `IS_ENTERPRISE`/`premium` (ver `docs/upstream/chatwoot-customizations.md`).

## 8. Seguridad de WhatsApp Cloud (revisión parcial pedida en el prompt, §10–11)

- **FACT:** `Webhooks::WhatsappController` aplica `verify_meta_signature!` a `process_payload` y usa `OpenSSL::HMAC` + `secure_compare` (`MetaTokenVerifyConcern`). Es correcto cuando se verifica.
- **FACT / HALLAZGO:** la verificación es **condicional** (`whatsapp_controller.rb:45-52`): para un canal `whatsapp_cloud` **sin app secret por canal y que no sea `embedded_signup`**, `meta_signature_verification_required?` devuelve `false` y el webhook se acepta **sin firma**. Upstream lo prueba explícitamente (`spec/controllers/webhooks/whatsapp_controller_spec.rb:204`, *skips signature validation for manual whatsapp cloud channels without an app secret*). Es una decisión de compatibilidad de upstream, **no un bug oculto**, pero para Terranet (probable setup manual) implica que quien conozca el número y un `phone_number_id` podría forjar mensajes entrantes.
- **FACT:** el secreto global `WHATSAPP_APP_SECRET` **no** activa la exigencia por sí solo en canales manuales: la exigencia depende de secretos del canal (`provider_config` claves `app_secret|app_secret_key|api_secret|client_secret`) o de `source == 'embedded_signup'`.
- **DECISION propuesta:** (1) mitigación por configuración: guardar `app_secret` de la app de Meta en `provider_config` de cada canal manual (**UNVERIFIED** si la UI/API lo permite sin consola); (2) si no, parche T3 mínimo (TN-P04) para exigir firma cuando exista `WHATSAPP_APP_SECRET` global o una bandera propia, con spec en `spec/terranet/`; proponerlo también a upstream.
- **FACT:** `provider_config` es `jsonb` en claro; solo `business_management_token` se cifra (`encrypts … if Chatwoot.encryption_configured?`, `app/models/channel/whatsapp.rb:31`). Tokens (`api_key`), `webhook_verify_token` y secretos de app quedan en claro en la DB y en sus backups. Los logs de parámetros filtran claves que contengan `secret`, `_key`, `token`, `access`, etc. (`config/initializers/filter_parameter_logging.rb`); la redacción en **respuestas JSON/serialización** y en Sentry **no se ha verificado** (UNVERIFIED).
- **Pendiente:** tests de seguridad propios (firma ausente/ inválida/ válida; canal manual con y sin secreto; no fuga de `provider_config` en la API de inbox) — sin número real, con fixtures.
