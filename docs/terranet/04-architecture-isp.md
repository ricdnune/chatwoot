# 04 — Arquitectura ISP: contexto 360 del abonado (diseño, aún sin código)

Estado: **propuesta (DECISION)** para M4–M8. No hay implementación en esta iteración. Todo lo marcado FACT proviene de este checkout (`v4.19.1`).

## 1. Objetivo

Que el agente diagnostique y atienda a un abonado **sin salir de la conversación**, con datos reales, frescos y auditables, sin romper la actualización upstream. Cinco bloques en el panel de la conversación: **Cliente · Servicio · Facturación · Red · Soporte**.

## 2. Principios

1. **Rails monolítico primero.** Sin microservicios: los adaptadores viven en Rails (jobs Sidekiq + caché Redis). Un servicio externo solo se justifica si hay costo medido (latencia, versionado, aislamiento de credenciales).
2. **Solo lectura en el MVP** (WispHub y SmartOLT). Cero reboot, reprovisión, VLAN, suspensión/reactivación, pagos o facturas.
3. **La UI nunca ve JSON de proveedor.** Solo esquemas normalizados propios.
4. **Nunca autovincular ante ambigüedad.** El vínculo lo confirma un agente y queda auditado.
5. **Todo dato externo lleva procedencia y frescura.** No se hace pasar un dato cacheado por medición en vivo.
6. **`account_id` en toda tabla nueva** y scopes por cuenta (aislamiento multi-account de Chatwoot).
7. **Extensión modular (T2)**: código propio en namespace `Terranet::` / carpeta `terranet/`; cambios a archivos upstream solo los mínimos y registrados en `docs/upstream/chatwoot-customizations.md`.
8. **Sin código de `enterprise/`**: si hiciera falta una capacidad premium (p. ej. audit logs, custom roles) → (A) licenciarla o (B) implementación original sobre componentes MIT.

## 3. Puntos de extensión verificados en el código

| Necesidad | Punto existente (FACT) | Nota |
|---|---|---|
| Panel lateral de conversación | `app/javascript/dashboard/routes/dashboard/conversation/ContactPanel.vue` | Insertar una sección nueva `TerranetSubscriberPanel` (componente propio) con un `<script setup>`; reglas del repo: Composition API, Tailwind only, i18n sin strings sueltas |
| Estructura de datos del contacto | modelos `Contact`, `ContactInbox`, `additional_attributes` / `custom_attributes` (jsonb) | **No** usar `custom_attributes` como base de verdad de bindings: no es auditable ni tiene FK/índices propios |
| Jobs/colas | Sidekiq 7.3.10, `config/sidekiq.yml`, `config/schedule.yml` (sidekiq-cron) | Colas separadas `terranet_isp_low/high`, para no competir con mensajería |
| Caché | Redis (`$alfred`, `Redis::Alfred`) | Claves con prefijo `terranet:isp:{account_id}:…` y TTL explícito |
| Autorización | Pundit (`app/policies`), roles `administrator`/`agent` | Políticas nuevas por recurso; sin custom roles (premium) |
| HTTP saliente | `HTTParty`/`RestClient` ya en Gemfile | Reusar; timeouts explícitos |
| Auditoría | `audit_logs` es **premium** (`enterprise/config/premium_features.yml`) | Tabla propia `terranet_isp_audit_events` (original, no copia) |

## 4. Modelo de datos propuesto (todas con `account_id`, `created_at`, `updated_at`)

```
terranet_subscriber_bindings        -- vínculo contacto ↔ abonado (explícito y auditable)
  account_id, contact_id, provider (wisphub), external_customer_id,
  status (pending|confirmed|rejected|revoked), match_basis (jsonb: qué evidencias coincidieron),
  confirmed_by_user_id, confirmed_at, revoked_by_user_id, revoked_at, note

terranet_service_links              -- contrato/servicio dentro de un binding
  account_id, binding_id, provider, external_service_id, install_address_hash, onu_serial,
  smartolt_onu_external_id

terranet_identity_evidence          -- evidencias usadas (hash/HMAC, no PII en claro cuando sea posible)
  account_id, binding_id, kind (phone_e164|document_id|contract_id|serial|address), value_digest, verified_by_user_id

terranet_isp_snapshots              -- última lectura normalizada por bloque
  account_id, binding_id, block (customer|service|billing|network|support),
  payload (jsonb, esquema normalizado), source, external_id, fetched_at, freshness, status, error

terranet_isp_audit_events           -- quién vio/hizo qué
  account_id, user_id, conversation_id, binding_id, operation, source, status, request_id, occurred_at
```

Reglas de identidad:
- Teléfono **E.164 normalizado, nunca clave única absoluta**: soportar teléfonos compartidos, varios contratos por cliente, varios clientes por teléfono, números reasignados y duplicados.
- Cédula/documento solo con permiso explícito y almacenada como digest cuando baste para comparar.
- Si hay >1 candidato o evidencia débil → estado `pending` con lista de candidatos para que el agente elija; **sin autovinculación**.
- Cada confirmación registra agente y hora; revocar es un evento, no un borrado.

## 5. Contrato normalizado (lo único que consume la UI)

Cada bloque devuelve este envoltorio:

```json
{
  "block": "network",
  "source": "smartolt",
  "external_id": "…",
  "fetched_at": "2026-10-27T15:04:05Z",
  "freshness": "live | cache | stale | unavailable",
  "status": "ok | degraded | error | not_linked",
  "error": { "code": "timeout", "message": "…" },
  "data": { }
}
```

- `freshness`: `live` = leído en esta petición; `cache` = dentro del TTL; `stale` = pasó el TTL pero se muestra con aviso; `unavailable` = sin dato. La UI rotula **CACHE / STALE / UNAVAILABLE** y muestra `fetched_at`.
- **Semáforos solo con estado verificado y umbrales definidos** (configurables por cuenta): p. ej. RX óptico fuera de rango, ONU offline confirmado, mora por días de atraso. Sin dato fresco → gris "sin dato", nunca verde por defecto.

Esquemas `data` (borrador):
- `customer`: `display_name`, `document_id_masked`, `phones[]`, `email_masked`, `status`.
- `service`: `contract_id`, `plan`, `status`, `install_address`, `ip` (si aplica).
- `billing`: `balance`, `overdue_days`, `last_invoice {id, amount, due_date, status}`, `last_payment {amount, paid_at}`, `suspended` (solo lectura).
- `network`: `onu_serial`, `onu_status`, `rx_dbm`, `tx_dbm`, `olt`, `pon_port`, `last_reading_at`, `alarms[]`.
- `support`: conversaciones previas, notas, responsables, eventos, próximas acciones (fuente: Chatwoot).

## 6. Capa `ISP Context` (backend)

```
Terranet::IspContext::Resolver        -- orquesta bloques para una conversación (policy-checked)
Terranet::IspContext::Adapters::Base  -- interfaz: fetch_customer/service/billing/network → normalizado
  ::Fake        (M4, fixtures sintéticos, contract tests)
  ::Wisphub     (M5, read-only)
  ::Smartolt    (M6, read-only)
Terranet::IspContext::Cache           -- TTL por bloque, stale-while-error
Terranet::IspContext::CircuitBreaker  -- por proveedor/cuenta
```

Controles de resiliencia por adaptador: timeout corto (p. ej. 3–5 s), reintentos con backoff+jitter solo en GET idempotentes, circuit breaker con estado visible ("proveedor degradado"), límite de concurrencia/rate por proveedor, métricas e instrumentación (latencia, errores, hit-rate de caché), **logs redactados** (sin tokens, sin PII).
API interna: `GET /api/v1/accounts/:account_id/terranet/conversations/:id/isp_context` (Pundit; devuelve solo el contrato §5; `Cache-Control: no-store`).

## 7. Integraciones (UNVERIFIED hasta leer la documentación oficial vigente)

- **WispHub** — cliente, contrato/servicio, estado, plan, dirección, saldo, facturas, pagos, suspensión: **UNVERIFIED** qué endpoints, paginación, límites y campos existen. Primero: estudiar documentación oficial vigente y exportaciones previas autorizadas (el proyecto local `wisphub-historical-export` puede servir como *referencia de forma de datos* únicamente tras revisión; no copiar datos reales al lab).
- **SmartOLT** — ONU/ONT, serial, OLT/PON, RX/TX, estado, timestamps, alertas: **UNVERIFIED**.
- Fase inicial: fixtures sintéticos + adaptador `Fake`; **sin** claves ni llamadas reales. Fase posterior (con autorización escrita): tokens de **solo lectura** en secret store, sandbox, logs redactados.
- Futuras escrituras (fuera del MVP): permiso específico, confirmación humana (doble en acciones críticas), `Idempotency-Key`, auditoría antes/después, timeout/rollback.

## 8. Fases (alineadas al roadmap)

| Fase | Entregable | Criterio de aceptación |
|---|---|---|
| M4 | Tablas de bindings + adaptador Fake + panel 360 con datos sintéticos | Vincular/rechazar/revocar con auditoría; casos ambiguos (teléfono compartido, 2 contratos) nunca autovinculan; UI muestra CACHE/STALE/UNAVAILABLE; specs de aislamiento por `account_id` |
| M5 | WispHub read-only | Contract tests contra fixtures; caída del proveedor degrada el panel sin romper la conversación |
| M6 | SmartOLT read-only | Idem; semáforos solo con lectura fresca |
| M7 | Historial unificado (eventos, notas, tickets, métricas de atención) | Línea de tiempo por abonado con fuente por evento |
| M8 | Acciones controladas + IA | Solo con RBAC y auditoría probados y licencias resueltas; ninguna acción destructiva automática |

## 9. Riesgos y pendientes

- PII (cédula, dirección, teléfono): minimizar, enmascarar en UI por defecto, retención según política Terranet/normativa ecuatoriana aplicable (**pendiente definir con el responsable legal**).
- El panel agrega superficie de datos sensibles: Pundit estricto, `no-store`, sin PII en logs/Sentry (ver telemetría en `03-privacy-egress-audit.md`).
- Alcance: este diseño asume `account_id` único de Terranet pero no lo hardcodea.
