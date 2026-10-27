# 12 — Módulo "Terranet ISP" en Super Admin (M4.1, prototipo local con mocks)

Base: `v4.19.1`, edición Community. **Estado: prototipo de laboratorio. Nada de esto está aprobado para producción**: toda la lógica de proveedores se probó solo contra un servidor mock local y datos sintéticos; **no se usó ningún token real ni se contactó a WispHub, SmartOLT, Meta, R2 ni Chatwoot.**
Convención: **FACT** (ejecutado/observado) · **INFERENCE** · **UNVERIFIED** · **DECISION**.
Decisión de arquitectura: ADR `07` opción A (aprobada por el propietario solo para prototipo local); identidad según `08` como diseño inicial (ningún vínculo se confirma automáticamente).

## 1. Qué se puede ver y hacer hoy
Entrar a **Super Admin → Terranet ISP** (`/super_admin/terranet_isp`, barra lateral "Manage"). Pestañas (todas por cuenta, con selector de cuenta si hay más de una):

| Pestaña | Contenido | Captura |
|---|---|---|
| General | versión del módulo, modo (simulado/en vivo), estado de la telemetría de Chatwoot (modo privacidad), **si el cifrado de credenciales está configurado**, candidatos de identidad pendientes, estado y latencia de cada proveedor | `evidence/m4/01-general.jpg` |
| WispHub | entorno sandbox/producción, estado de la credencial, fecha de rotación, campo "Nueva Api-Key" (siempre vacío), **Probar conexión**, última comprobación e historial | `02-…` |
| SmartOLT | subdominio estructural validado (`<nombre>.smartolt.com`), estado del X-Token, prueba, resultado (p. ej. `rate_limited`) | `03-…` |
| Identidad | candidatos sintéticos servicio ↔ ONU ↔ contacto; confirmar / rechazar / revocar con **motivo de una lista**; nada se confirma solo | `04-…`, `05-…` |
| Auditoría | actor, acción, resultado y metadatos permitidos de cada configuración, prueba o decisión | `06-…` |

Además: móvil y modo oscuro sin desbordes (`07-wisphub-mobile-dark.jpg`). Idiomas: `en` y `es` (`config/locales/terranet_isp.{en,es}.yml`, mismas 92 claves); Super Admin usa `en` por defecto.

**Cómo verlo en el laboratorio** (usuario y datos de ejemplo del seed público de upstream; `lab.sh` documenta el resto):
```bash
terranet/lab/lab.sh up                       # arranca Rails, Sidekiq, Vite, Mailpit y el mock ISP; migra y aplica el branding
terranet/lab/lab.sh rails terranet:isp:seed_synthetic    # contactos y servicios FALSOS (solo modo mock, nunca en producción)
# navegador: http://127.0.0.1:13000/super_admin/terranet_isp
```
Credenciales **falsas** para probar (el mock elige el comportamiento por prefijo, 8+ caracteres): `mock-ok-…` (200), `mock-401-…`, `mock-403-…`, `mock-404-…`, `mock-429-…` (429 + `Retry-After`), `mock-redirect-…` (302 hacia una dirección interna), `mock-slow-…` (tarda 12 s, el cliente corta a los 8 s), `mock-huge-…`, `mock-html-…`, `mock-leaky-…` (JSON con campos `password*`). No son tokens reales y no abren nada.

## 2. Qué se construyó (T2: archivos nuevos; ver registro TN-015..019)
```
lib/terranet/isp.rb                          espacio de nombres, modo (mock por defecto), comprobación de cifrado
lib/terranet/isp/endpoint.rb                 construye la ÚNICA URL permitida; bloquea destinos no públicos
lib/terranet/isp/secure_http.rb              cliente GET-only: sin redirecciones, tiempo/tamaño acotados, solo JSON
lib/terranet/isp/providers{,/wisphub,/smartolt,/base}.rb   adaptadores + DTO con lista blanca estricta
app/models/terranet/isp/{provider_credential,connection_check,audit_event,binding}.rb
app/services/terranet/isp/connection_tester.rb
app/controllers/terranet/isp/admin/*         Base < SuperAdmin::ApplicationController (authenticate_super_admin!, CSRF)
app/views/terranet/isp/admin/**              vistas con el sistema de diseño de Super Admin
config/initializers/terranet_isp.rb          rutas (routes.prepend) + entrada de menú (prepend) — sin editar archivos upstream
lib/terranet/isp/navigation_extension.rb
db/migrate/20261027212607_create_terranet_isp_tables.rb  (+ db/schema.rb: único archivo upstream tocado, ver TN-016)
terranet/lab/mocks/isp/config.ru             servidor mock (datos sintéticos)
```

### 2.1 Datos (4 tablas, sin FK de BD, `account_id` explícito en todas)
`terranet_isp_provider_credentials` (única por cuenta+proveedor; entorno, subdominio, `secret` **cifrado**, estado, última prueba, enfriamiento por 429, rotación) · `terranet_isp_connection_checks` (historial acotado a 200 por credencial; solo inserción) · `terranet_isp_audit_events` (solo inserción; metadatos con lista blanca) · `terranet_isp_bindings` (candidato / confirmado / rechazado / revocado, con motivo y decisor).
**Rollback verificado**: `db:rollback` elimina las 4 tablas y `db:migrate` las recrea (BD de pruebas).

### 2.2 Rutas (todas bajo `/super_admin/terranet_isp`, solo Super Admin)
`GET /` (redirige a la primera cuenta) · `GET /accounts/:id` · `GET|PATCH /accounts/:id/providers/(wisphub|smartolt)` (ajustes: solo `environment` o `subdomain`) · `PATCH …/providers/:p/secret` (único camino para guardar/rotar el secreto) · `POST …/providers/:p/test` · `GET /accounts/:id/identity` · `POST …/identity/:id/decision` · `GET /accounts/:id/audit`.
`account_id` solo acepta dígitos; un id inexistente devuelve 404; ningún parámetro del cuerpo decide la cuenta, el rol ni una URL.

## 3. Credenciales (reglas del ADR §5.4, comprobadas)
| Regla | Cómo se cumple | Prueba |
|---|---|---|
| Cifrado en reposo, no determinista | `encrypts :secret` (Active Record Encryption); la columna contiene `{"p":…}` y no el valor | spec + inspección SQL en el lab: `plaintext_in_column=false`, `encrypted?=true` |
| **Fail-closed** | sin `ACTIVE_RECORD_ENCRYPTION_*`: guardar lanza `EncryptionNotConfigured`, leer y probar se rechazan, el formulario se desactiva y General lo muestra en rojo | specs modelo + request (sin claves ⇒ 0 filas) |
| No confiar en texto claro heredado | `secret_value` exige que el valor sea realmente texto cifrado (upstream activa `support_unencrypted_data`, que aceptaría texto claro) | spec: valor inyectado en claro ⇒ error |
| Nunca vuelve al cliente | el campo llega **vacío** (`value: nil`, `autocomplete=new-password`); tras guardar solo se muestra "guardada cifrada, no se vuelve a mostrar" | spec de HTML + comprobación en el navegador (`inHtml:false`, `inStorage:false`, `inCookie:false`) |
| No en `inspect`/JSON/logs/auditoría | `inspect` → `[FILTERED]`; `serializable_hash` excluye `secret`; `filter_parameters` redacta `secret`; auditoría y resultado de red sin valor ni cuerpo | specs + `grep` del log de desarrollo: 0 apariciones del token de prueba |
| Rotación | nuevo valor obligatorio (8–512 ASCII imprimibles, sin espacios ni saltos ⇒ también evita inyección de cabeceras); se registra actor y fecha, nunca el valor anterior | specs |
| Sin `secret_hint` | **DECISIÓN (instrucción de la misión):** no se guarda ni muestra ningún fragmento | — |
| Cambio de entorno | cambiar sandbox↔producción **elimina** el secreto (cada entorno tiene su clave) | spec |

**Aviso de ámbito:** `credential.attributes` devuelve el texto plano por diseño de Rails; no debe registrarse nunca. En producción hay que generar y custodiar las claves `ACTIVE_RECORD_ENCRYPTION_*` **fuera de la base de datos y de los backups** y que sean **idénticas en ambos nodos**; sin ellas los secretos son irrecuperables.

## 4. Seguridad de red (sin egress real)
- **Modo `mock` por defecto**: la URL sale de `TERRANET_ISP_MOCK_URL` (por defecto `http://isp-mock:4010`), que solo admite orígenes locales sin ruta ni usuario (`isp-mock`, `localhost`, `127.0.0.1`, `*.test`). El modo `live` solo existe tras `TERRANET_ISP_MODE=live` y **no está aprobado**; sus rutas se probaron únicamente con WebMock (sin red).
- En modo live la URL se **construye**: WispHub = host fijo por entorno (`api.wisphub.net`/`sandbox-api.wisphub.net`); SmartOLT = `https://<subdominio>.smartolt.com`, subdominio `[a-z0-9-]` sin puntos, barras, `@`, `:` ni mayúsculas. HTTPS con verificación de certificado; la IP resuelta se **fija** y se rechaza si **cualquiera** de las direcciones es privada, loopback, link-local o CGNAT (anti SSRF / DNS rebinding).
- Cliente: solo `GET`, **nunca sigue redirecciones** (un 302 se informa como `redirect_blocked` y no se hace la segunda petición), conexión 3 s / lectura 8 s, cuerpo ≤ 256 KB, solo `application/json`. Resultado = código estable (`unauthorized`, `forbidden`, `not_found`, `rate_limited`, `timeout`, `response_too_large`, `redirect_blocked`, `invalid_response`…), **nunca el cuerpo**.
- `429`: se lee `Retry-After` (acotado a 1 h, 60 s por defecto), se guarda un enfriamiento y **no se hace ninguna llamada** mientras dure (`rate_limited_locally`). La señal óptica no se consulta nunca (solo lista de OLT/1 cliente; ADR §3).
- **FACT (lab):** el contenedor Rails hizo 24 consultas DNS en la sesión, **todas a `isp-mock`**; ningún nombre externo (los nombres externos del log son del control de la auditoría). `audit-egress`: **PASS** (privacidad ON: 0 DNS y 0 paquetes prohibidos; el control con privacidad OFF sí los detecta).

## 5. Matriz de permisos (probada con requests)
| Actor | `GET` de las 5 pestañas | Guardar secreto / ajustes / probar / decidir |
|---|---|---|
| Sin sesión | redirige a `/super_admin/sign_in` | redirige; **0 filas y 0 eventos** creados |
| Agente (sesión de la app) | redirige a sign-in | redirige; 0 filas |
| Administrador de cuenta | redirige a sign-in | redirige; 0 filas |
| Super Admin | 200 | permitido, auditado |
Cada petición del agente/administrador se hizo con una sesión válida de la app (login de un solo uso por petición). Parámetros `type=SuperAdmin`, `role`, `super_admin` **no elevan** (el usuario sigue sin `type`).
**Aislamiento por cuenta (IDOR):** con 2 cuentas sintéticas, la página de la cuenta B no muestra la credencial de A; un `PATCH …/secret` con `account_id` en el cuerpo solo escribe en la cuenta de la URL; probar la conexión de B cuando la credencial existe solo en A ⇒ 404 y sin llamada; decidir un candidato de A desde la URL de B ⇒ 404 y estado intacto; auditoría y contactos listados solo los de la cuenta de la URL.
**CSRF:** con la protección activada, un `PATCH` sin token ⇒ 422 y nada guardado.

## 6. Resultados de pruebas (2026-10-27, secuenciales)
| Comando / puerta | Resultado |
|---|---|
| Specs ISP (modelo 16, endpoint 6, transporte 14, proveedores 6, servicio 10, request 24 = 76 ejemplos) | **0 fallos** |
| ISP + branding (24) + `spec/controllers/super_admin` (conjunto completo) | **246 ejemplos, 0 fallos** |
| Misma colección en **copia sin `enterprise/`** (`lab.sh foss-check`) | **246 ejemplos, 0 fallos** (el correo de confirmación renderiza; `enterprise?=false`, plan Community) |
| RuboCop sobre los 36 archivos Ruby nuevos | sin ofensas |
| `audit-egress` | **PASS** |
| Migración: rollback + re-migrar en BD de pruebas | OK (4 tablas desaparecen y reaparecen) |
| Pruebas de mutación (cada una rompe el código de forma deliberada y **debe** hacer fallar al menos un spec) | **8/8 detectadas**: sin guardia fail-closed; aceptar texto claro; lista blanca que deja pasar `password`; IDOR en prueba de conexión; IDOR en decisión; auditoría sin lista blanca; redirección tratada como éxito; secreto re-renderizado en el formulario |
**Honestidad:** una ejecución FOSS intermedia dio 6 fallos; **no eran del código** sino de mi propia prueba de migración, que dejó 128 filas de `installation_configs` en la BD de pruebas; se limpió esa BD de pruebas y la misma colección pasó 246/0. Otra ejecución de mutación dio 12 fallos por una edición concurrente mía; se repitió aislada: 1 fallo, como se esperaba.
No se ejecutaron: la suite completa de RSpec, Vitest ni ESLint (no se cambió JS/Vue en M4.1), ni pruebas de carga.

## 7. Diferencias respecto al ADR 07 (decisiones tomadas al construir)
- Una credencial por cuenta y proveedor (no por entorno): el cambio de entorno elimina el secreto. Más simple y evita dos claves vivas por error.
- Sin `secret_hint` y sin columna `base_url_host` (el host se **construye**, no se guarda); sin IP en auditoría (solo `request_id`).
- La prueba de WispHub usa `GET /clientes/?limit=1`; **UNVERIFIED** contra el sandbox real (la ruta sale del OpenAPI público).
- Panel "Cliente ISP" en la conversación, sincronización, caché con frescura `live/cache/stale/unavailable`, eventos SSE de SmartOLT y MFA: **no implementados** (M5+).
- La identidad es una **pantalla de modelo con datos sintéticos**: no hay importación, ni emparejado automático, ni PII real.

## 8. Reversión
`git revert` de los commits de la rama; `rails db:rollback` (elimina las 4 tablas y sus datos); borrar el servicio `isp-mock`. El módulo no toca `installation_configs` ni ningún dato de Chatwoot.

## 9. Pendiente antes de cualquier uso real (verificable)
1. Aprobación del propietario + claves `ACTIVE_RECORD_ENCRYPTION_*` de producción y su custodia.
2. Usuario WispHub de solo lectura y token SmartOLT de lectura **inyectados por canal seguro** (nunca por chat) en un entorno de staging autorizado, con FQDN permitidos en el firewall.
3. Verificar en sandbox real: ruta/semántica de la prueba de WispHub, límites de tasa, formato de errores.
4. MFA para las cuentas Super Admin y revisión de la política de retención de auditoría (normativa local por confirmar).
5. M2.2 (cifrado/redacción de `provider_config` de WhatsApp) y despliegue de M2.1 antes de usar Meta en un despliegue nuevo.
