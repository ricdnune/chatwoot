# 03 — Privacidad y egress (M2)

Base: `terranet/main` = `v4.19.1` · Rama de trabajo: `terranet/feature/m2-privacy-egress` · Edición: **Community (Camino B, decisión del propietario)**.
Convención: **FACT** (archivo o ejecución en el lab) · **INFERENCE** · **DECISION** · **UNVERIFIED**.

## 1. Estado

| Criterio de cierre de M2 | Estado |
|---|---|
| Telemetría/relay/registro controlados por código **y** tests | ✅ `TERRANET_PRIVACY_MODE` + 19 specs propios + auditoría de egress (§5) |
| Árbol Git no se modifica inadvertidamente | ✅ `lab.sh` solo **informa** (exit 3), no revierte; annotate y volcado de schema neutralizados por configuración (§6) |
| Laboratorio arranca correctamente | ✅ arranque desde cero verificado (§5.4) |
| Excepciones a la política documentadas | ✅ §8 |
| Pendiente (no bloquea M2) | Push móvil real (sin app móvil), HMAC WhatsApp (→ M2.1), artefacto de producción sin `enterprise/` (§7) |

## 2. Hallazgos principales (FACT, con evidencia en §5)

1. **`DISABLE_TELEMETRY=true` no basta.** Quita contadores/eventos pero el job diario sigue enviando a `hub.2.chatwoot.com/ping`: `installation_identifier`, `installation_version`, `installation_host`, `installation_env`, `edition`. Además cualquier valor de la variable (incluso `false` o vacío) la activa (`lib/chatwoot_hub.rb:88,122`).
2. **El onboarding envía datos del propietario por defecto:** la casilla "subscribe to updates" viene **premarcada** (`app/views/installation/onboarding/index.html.erb`) y dispara `register_instance` con nombre de empresa, nombre y email del dueño. Afecta a toda reinstalación/instancia nueva.
3. **Bloquear solo por red es ruidoso:** con el hub inalcanzable, `Internal::CheckNewVersionsJob` falla cada día con `NoMethodError: undefined method '[]' for nil` (`sync_with_hub` devuelve `nil` tras rescatar el error y el job indexa `@instance_info['version']`). Se observó en el control del laboratorio. Por eso el control principal es de **aplicación**, no solo de red.
4. **Gravatar y Google Favicons envían datos de contactos:** `www.gravatar.com` (MD5 del email) y `www.google.com/s2/favicons?domain=…` (dominio de la empresa del contacto). Ambos observados por DNS en el laboratorio sin controles.
5. **`DISABLE_GRAVATAR` se persiste:** `GlobalConfigService.load` copia la variable a `installation_configs` en la primera lectura (si se quita después, sigue activa) y varias lecturas concurrentes compiten por el índice único (se vieron `PG::UniqueViolation` reintentados). Mitigación: precalentar la lectura en el arranque (`lab.sh up` lo hace).
6. **En Enterprise licenciado el mismo ping trae el plan** (`Enterprise::Internal::CheckNewVersionsJob#update_plan_info`). No aplica en el Camino B, pero explica por qué no se toca `enterprise/`.
7. **`DISABLE_ENTERPRISE=true` no es suficiente en Community:** `config/application.rb:49` antepone `enterprise/app/views` aunque la variable esté activa y el correo `devise/mailer/confirmation_instructions` de Enterprise llama a `Account#saml_enabled?` (solo existe en Enterprise) → **10 fallos** en `spec/mailers/confirmation_instructions_spec.rb` y el correo de confirmación/invitación no se genera. Con una copia **sin `enterprise/`** (como hace el workflow FOSS de upstream, `run_foss_spec.yml:121-124`): 0 fallos. Ver §7.

## 3. Controles implementados

| Control | Tipo | Dónde | Efecto |
|---|---|---|---|
| `TERRANET_PRIVACY_MODE=true` | **parche T3 mínimo (48 líneas netas en `app/`+`lib/`)** | `lib/terranet/privacy.rb`, `lib/terranet/chatwoot_hub_privacy.rb`, +1 línea en `lib/chatwoot_hub.rb`, +1 en `app/jobs/avatar/avatar_from_favicon_job.rb`, casilla oculta en `app/views/installation/onboarding/index.html.erb` | Ninguna petición a `hub.2.chatwoot.com` (ping, registro, push relay, eventos). `sync_with_hub` devuelve `{}` (el job queda como no-op **sin suprimir excepciones**). No se pide el favicon a Google (la UI usa su avatar de iniciales). Casilla de suscripción oculta |
| `DISABLE_TELEMETRY=true` | config (upstream) | env | se mantiene como defensa adicional |
| `DISABLE_GRAVATAR=1` | config (upstream) | env | no se consulta Gravatar |
| `ENABLE_PUSH_RELAY_SERVER=false` | config (upstream) | env | `PushNotificationService` no usa el relay (gate en `push_notification_service.rb:114-116`) |
| `DISABLE_ENTERPRISE=true` | config (upstream) | env | edición Community (+ ver §7) |
| `ENABLE_ACCOUNT_SIGNUP=false` | config (upstream) | env | `/app/auth/signup` redirige a login; no se piden testimonios |

Diseño del parche (fácil de rebasar): un módulo `prepend` sobre `ChatwootHub.singleton_class` que cubre los **cuatro** únicos métodos que llegan a la red (`sync_with_hub`, `register_instance`, `send_push_with_response` —de donde cuelga `send_push`—, `emit_event`). No se tocó `enterprise/`. Off por defecto: sin la variable el comportamiento upstream es idéntico.

## 4. Destinos externos — antes / después

| Destino | Motivo upstream | Datos | Antes (M1) | Después (privacidad ON) | Decisión |
|---|---|---|---|---|---|
| `hub.2.chatwoot.com/ping` | versión/telemetría (diario, prod) | id instalación, versión, host, env, edición (+ contadores sin `DISABLE_TELEMETRY`) | enviaba | **0 consultas DNS, 0 paquetes** | **Bloquear** |
| `…/instances` | registro en onboarding | empresa, nombre, email del dueño | enviaba si casilla marcada (premarcada) | no se ofrece ni se envía | **Bloquear** |
| `…/send_push` | relay push apps móviles oficiales | token FCM, título/URL, id instalación | enviaba salvo `ENABLE_PUSH_RELAY_SERVER=false` | no se envía | **Bloquear** (impacto §9) |
| `…/events` | eventos | evento + id | sin llamadores en v4.19.1 | no se envía | **Bloquear** |
| `…/changelogs` (navegador) | tarjeta de novedades | IP/UA del agente | solo si `isOnChatwootCloud` (`Sidebar.vue:1089-1102`) | no se solicita (0 hosts externos en 7 pantallas) | **Bloquear** |
| `testimonials.cdn.chatwoot.com` | pantalla de signup | IP/UA | solo en signup | signup redirige; 0 peticiones | **Bloquear** |
| `www.gravatar.com` | avatar por email | MD5 del email | consultaba (2 consultas DNS) | 0 (con `DISABLE_GRAVATAR`) | **Bloquear** |
| `www.google.com/s2/favicons` | avatar de empresa | dominio de la empresa | consultaba | 0 (modo privacidad) | **Bloquear** |
| `stun.l.google.com` | llamadas de voz (código **Enterprise**) | IP | no activo en Community | no activo | Bloquear (si algún día se usan llamadas, decisión aparte) |
| Widget de soporte en Super Admin | soporte Chatwoot | email/nombre del primer SuperAdmin | solo si `CHATWOOT_SUPPORT_*` poblados (los puebla el hub, §2.6) | `/packs/js/sdk.js` se pide **al propio servidor** con token vacío; 0 hosts externos | Dejar vacío |
| Sentry/Datadog/APM/Amplitude/Clarity… | observabilidad | — | solo con DSN/tokens | no configurados | Bloquear salvo decisión explícita |
| Analítica del Help Center (GA4/GTM/Hotjar/Plausible/Pixel…) | portales | visitantes | solo si un admin pone IDs | no configurado | Política: no usar |
| `openrouter.ai` / OpenAI (Captain) | IA | conversaciones | solo con claves; Captain es **Enterprise** | no aplica en Community | n/a |
| `www.chatwoot.com`, `chwt.app`, `status.chatwoot.com`, `chatwoot.help` | enlaces de ayuda | — | solo al hacer clic | idem | Permitir como **enlaces manuales** |
| `github.com` | upstream (solo desarrolladores) | — | `git fetch` | idem | Permitir en máquina de desarrollo; **no** en runtime |

## 5. Pruebas y evidencia (ejecutadas el 2026-10-27)

### 5.1 Specs propios — `./lab.sh rspec-terranet` → **19 ejemplos, 0 fallos**
Archivos: `spec/lib/terranet/chatwoot_hub_privacy_spec.rb`, `spec/lib/terranet/privacy_spec.rb` (tripwire de actualización), `spec/jobs/internal/check_new_versions_job_privacy_spec.rb`, `spec/jobs/avatar/avatar_from_{gravatar,favicon}_job_privacy_spec.rb`, `spec/controllers/installation/onboarding_controller_privacy_spec.rb`, `spec/services/notification/push_notification_service_privacy_spec.rb`.
- Con privacidad ON: ninguna llamada a `RestClient.post` ni petición WebMock a `*chatwoot.com`/`google.com` (WebMock del `spec_helper` bloquea toda conexión real).
- Con privacidad OFF y red **mockeada**: la telemetría sigue activa (contadores en `/ping`, `/events`) → cubre "tests que requieren telemetría habilitada" sin conectividad.
- `DISABLE_TELEMETRY` solo: el ping residual con identificador queda documentado como test.
- **Prueba de mutación:** quitando la línea `prepend` de `lib/chatwoot_hub.rb` fallan **6** ejemplos; restaurada, pasan los 19.
- Tripwire de upgrade (`privacy_spec.rb`): falla si aparece un llamador nuevo de `ChatwootHub`, un host `*.chatwoot.com` nuevo en constantes del frontend o un segundo archivo Ruby con `hub.2.chatwoot.com`.

### 5.2 Los dos fallos conocidos de `chatwoot_hub_spec` — **aislados, no eliminados**
Causa: el `.env` del lab define `DISABLE_TELEMETRY=true` y los specs upstream asumen telemetría activa. `lab.sh rspec` ahora corre **herméticamente** (quita las variables propias del lab, `SPEC_UNSET`) → `spec/lib/chatwoot_hub_spec.rb` pasa. `./lab.sh rspec-privacy` ejecuta lo mismo con los controles ON: fallan 6 ejemplos **esperados** (5 de hub que esperan HTTP + 1 de Gravatar que espera la cola), lo que documenta qué supuestos upstream cambian.

### 5.3 Conjuntos de regresión
| Comando | Resultado |
|---|---|
| `./lab.sh rspec spec/terranet…` (ver §5.1) | 19 / 0 fallos |
| `./lab.sh rspec spec/lib spec/controllers/installation spec/controllers/webhooks spec/jobs spec/mailers spec/services/notification spec/models/company_spec.rb spec/models/user_spec.rb spec/models/contact_spec.rb spec/helpers` (+ specs propios) | **1 492 ejemplos, 0 fallos** (con `spec/enterprise` excluido) |
| `./lab.sh vitest app/javascript/shared app/javascript/dashboard/helper` | 78 archivos, **1 672 tests** pasan |
| RuboCop sobre `lib/terranet`, `lib/chatwoot_hub.rb`, el job de favicon y los 8 specs tocados | **0 ofensas** |
| ESLint sobre `shared/constants`, `dashboard/constants`, `dashboard/api/changelog.js` | 0 errores (**no se cambió JS/Vue**) |
| Suite completa RSpec/Vitest | **No ejecutada** (pendiente; correrla antes de cada release) |

### 5.4 Arranque limpio y flujos (laboratorio)
`./lab.sh reset && ./lab.sh up` → rc=0 en ~25 s con imagen en caché; `/api` = `{"version":"4.19.1","queue_services":"ok","data_services":"ok"}`; `git status` sin cambios no deseados. Login API 200; login UI → dashboard → conversación sintética "Jane"; correo de confirmación se renderiza (6 689 B); sidebar sin entradas Enterprise (Captain/Calls). **DNS del lab tras el arranque y navegación: ninguna consulta.** Sidekiq procesa `EventDispatcherJob`, `ActionCableBroadcastJob`, `TriggerScheduledItemsJob`, `Internal::CheckRingingTimeoutsJob`, `Avatar::AvatarFromGravatarJob` (no-op) sin errores (solo avisos de deprecación upstream de `enum`).

**Navegador (panel integrado), hosts cargados por pantalla:** login, dashboard, conversación 1, bandeja de inboxes, contactos, portales/Help Center (`portals/new`), Super Admin (`/super_admin/sign_in` y panel), `/app/auth/signup` (redirige a login): **todos solo `127.0.0.1:13000`**, 0 recursos externos, sin `testimonials`. Muestra amplia pero no exhaustiva (no se probaron el widget de chat ni el Help Center público con contenido).

### 5.5 Auditoría de egress del flujo de **producción simulado** — `./lab.sh audit-egress`
Corre `RAILS_ENV=production` sobre una DB desechable (`chatwoot_prodsim`, Redis índice 6) con datos sintéticos, ejecuta en línea: disparador diario → job de versión, `register_instance`, `emit_event`, `send_push`, creación de contacto (Gravatar), creación de empresa (favicon) y notificación con suscripción FCM; el runner enruta por `egress-sink` (tcpdump) y el DNS por `dns-sink`.

```
=== PRIVACY ON (production simulation)         env=production enterprise=nil privacy=true …
  ok × 8 pasos
--- DNS queries matching /chatwoot|gravatar|google/:   (none)
--- packets seen by egress-sink:                       (none)
=== CONTROL: privacy OFF (+ direct-IP probe)
  err daily trigger / version check: NoMethodError: undefined method '[]' for nil     <- hallazgo 3
--- DNS queries:   35 hub.2.chatwoot.com · 2 www.google.com · 2 www.gravatar.com
--- packets:        5 172.29.250.136 -> 192.0.2.1.443 · 1 172.29.250.136 -> 203.0.113.9.443 (IP directa, sin DNS)
AUDIT PASS: no forbidden DNS queries and no packets with privacy ON; control run detected
```
El script **falla (exit 2)** si el control no es detectado (detector ciego) y (exit 1) si hay fuga con privacidad ON. Limitación: cubre las rutas enumeradas; una llamada nueva no listada solo la atrapa el tripwire estático (§5.1) o el DNS/paquetes si el flujo la ejerce.

## 6. Efectos colaterales del laboratorio sobre el árbol Git (corregido)
- `annotate_rb` reescribía ~28 modelos (incl. `enterprise/`): se desactiva con **`ANNOTATERB_SKIP_ON_DB_TASKS=1`** (variable correcta de `lib/tasks/annotate_rb.rake`; en M1 se usó una incorrecta).
- `db:migrate` siempre vuelca `db/schema.rb` (`lib/tasks/db_enhancements.rake`): `lab.sh up` prepara la DB con una **copia desechable** montada sobre `db/schema.rb`; el archivo versionado no se toca (informa cuántas líneas habría cambiado). Para desarrollar migraciones se usa `lab.sh rails db:migrate` (sin copia) y los cambios aparecen en Git como corresponde.
- `lab.sh` ya **no** contiene `git checkout/restore/reset`; `with_tree_check` compara hashes de contenido de todo lo modificado o sin seguimiento antes/después, **informa** rutas y `git diff --stat` y devuelve **exit 3**. Prueba: un archivo sin seguimiento creado dentro del contenedor fue reportado y **no** se borró.

## 7. Edición Community — hallazgo de despliegue (**DECISION pendiente de aprobación**)
`DISABLE_ENTERPRISE=true` deja `enterprise/` en disco y en el `eager_load`; sus vistas siguen resolviéndose primero (hallazgo 2.7). Propuesta: **el artefacto de producción debe construirse sin `enterprise/` ni `spec/enterprise/`** (igual que la imagen FOSS de upstream), con `DISABLE_ENTERPRISE=true` como cinturón. Ventajas: correos correctos, sin código Enterprise en nodos de producción ni en imágenes (refuerza el cumplimiento de `enterprise/LICENSE`, que prohíbe distribuir/copiar), mismo camino que prueba upstream en CI. Verificado: `./lab.sh foss-check <specs>` arranca una copia temporal sin `enterprise/` → `enterprise?=false`, correo de confirmación OK, **198 ejemplos / 0 fallos** (specs propios, hub, onboarding, jobs internos, mailers). En el lab diario se enmascara `enterprise/app/views` con un `tmpfs` (solo contenedor) para que los correos funcionen: 1 492/0 fallos.
Pendiente: construir y probar la imagen de producción sin `enterprise/` (Dockerfile propio o `.dockerignore` de build) — misión separada, sin tocar PVE01/PVE02.

## 8. Excepciones y límites de la política de privacidad
1. **Navegador del agente:** el tráfico del navegador a terceros (p. ej. enlaces de ayuda al hacer clic) es decisión del usuario; el CSP/proxy corporativo es la defensa adicional (§10).
2. **Cobertura de código:** la política cubre las rutas inventariadas; se re-audita en cada upgrade con el tripwire de §5.1 y `audit-egress`.
3. **`DISABLE_GRAVATAR` persiste en la DB** (§2.5): si se desea volver atrás hay que borrar la fila `installation_configs.DISABLE_GRAVATAR` y limpiar caché.
4. **No se bloquea tráfico de canales/servicios necesarios** (Meta, R2, SMTP, WispHub, SmartOLT, DNS/NTP) — ver §11.
5. Las apps móviles oficiales pierden el relay (§9).

## 9. Push móvil — impacto de desactivar los relays (sin afirmar lo no probado)
- **FACT (código):** `PushNotificationService#perform` hace por suscripción `send_browser_push` (Web Push propio), `send_fcm_push` (solo con `FIREBASE_*` propios) y `send_push_via_chatwoot_hub` (relay). Con `ENABLE_PUSH_RELAY_SERVER=false` o modo privacidad, el relay **no se invoca/no sale a la red** (probado en spec con suscripción FCM sintética).
- **No probado:** el efecto sobre las **apps móviles oficiales** (no hay app/dispositivo en el lab). **INFERENCE:** dependen del relay (su Firebase es de Chatwoot) y dejarían de recibir push; Web Push de navegador no depende del relay (no verificado en runtime con un navegador suscrito).
- **DECISION a confirmar con el operador:** aceptar solo Web Push o planificar una app/Firebase propios. No se declara que "funcionan" ni que "dejan de funcionar" hasta probarlo con un dispositivo en staging.

## 10. Defensa en profundidad de red (diseño, no desplegado)
Egress por FQDN desde los contenedores de producción vía proxy/DNS filtrante (el `dns-sink` del lab es el modelo): lista **permitida** = §11 + SMTP + NTP + DNS; todo lo demás denegado y registrado. Las IP/CDN cambian, así que se filtra por nombre. Validar con `audit-egress` en staging con la misma política antes de aplicar a producción (acción humana).

## 11. Matriz de conexiones futuras permitidas (**no conectadas todavía**)
| Servicio | Dirección | Destino / origen | Estado de verificación | Condiciones |
|---|---|---|---|---|
| Meta WhatsApp Cloud API (salida) | Rails/Sidekiq → Meta | `graph.facebook.com` (FACT: `Whatsapp::FacebookApiClient::BASE_URI`); descarga de medios en dominios CDN de Meta | host de API **FACT**; dominios de medios **UNVERIFIED** (medir en staging con DNS sink) | Solo por FQDN; token de larga duración en secret store |
| Meta WhatsApp (webhooks, entrada) | Meta → `…/webhooks/whatsapp/:phone` | IPs/ASN de Meta (rotan) | **UNVERIFIED** (documentación Meta) | **Exigir HMAC** (M2.1, ver `06`); no abrir más rutas |
| Cloudflare R2 | Rails → R2 (S3 compatible) | `<account>.r2.cloudflarestorage.com` vía `STORAGE_ENDPOINT` (FACT: `config/storage.yml` `s3_compatible`) | endpoint exacto **UNVERIFIED** hasta ver el bucket real | Bucket/credenciales de **staging** aisladas para pruebas; no tocar el productivo |
| WispHub | Sidekiq → API | FQDN **UNVERIFIED** (leer documentación oficial vigente) | read-only, token en secret store, rate limit y timeouts | Solo tras autorización escrita (M5) |
| SmartOLT | Sidekiq → API | FQDN/subdominio de la cuenta **UNVERIFIED** | read-only (M6) | Idem |
| SMTP Terranet | Rails → SMTP | host de Terranet | por definir | TLS |
| DNS/NTP | contenedores | resolvers/NTP corporativos | — | Reloj coherente (firmas, URLs firmadas) |

## 12. Riesgos, impacto en upgrades y reversión
- **Impacto en upgrades oficiales:** 3 archivos upstream tocados (`lib/chatwoot_hub.rb` +1 línea, `avatar_from_favicon_job.rb` +1 línea, `onboarding/index.html.erb` +4/−3) y 2 archivos nuevos bajo `lib/terranet/`. Riesgo de conflicto: **bajo**. Si upstream refactoriza `ChatwootHub` (nuevos métodos con red), el tripwire `privacy_spec.rb` y `audit-egress` lo detectan. Retirada: borrar `lib/terranet/`, la línea `prepend` y los dos guardas; los specs propios dejarían de aplicar.
- **Funcionalidad afectada:** sin aviso de nueva versión (`LATEST_CHATWOOT_VERSION` nunca se escribe → no hay banner de actualización; las actualizaciones las gestiona Terranet), sin push móvil oficial (§9), sin avatares automáticos de Gravatar/favicon (se muestran iniciales).
- **Reversión:** quitar `TERRANET_PRIVACY_MODE` (y `DISABLE_GRAVATAR`, borrando su fila de `installation_configs`) restaura el comportamiento upstream sin migraciones.
- **Pendiente:** correr la suite completa; staging con proxy/DNS filtrante; imagen sin `enterprise/` (§7); prueba de push con dispositivo; cobertura del widget de chat y Help Center público.
