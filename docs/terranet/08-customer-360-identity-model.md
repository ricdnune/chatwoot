# 08 — Modelo de identidad y Customer 360 (M5.0 — diseño, sin código)

Estado: **PROPUESTA**; depende del ADR `07`. Base `v4.19.1`. Convención: **FACT** · **INFERENCE** · **DECISION** · **UNVERIFIED**.
Alcance: esquema normalizado, reglas de vinculación abonado ↔ contacto/conversación, panel "Terranet · Cliente ISP", trazabilidad y pruebas. **No hay implementación ni datos reales.**

## 1. Fuentes y claves reales (de la documentación oficial, ver `07` §3)

| Dato | WispHub (FACT, `components/Clientes.yaml`) | SmartOLT (FACT, OpenAPI) |
|---|---|---|
| Clave estable del servicio | `id_servicio` (entero) | — |
| Clave estable de la ONU | — | `unique_external_id` (cadena); además `sn` |
| Serial ONU | `sn_onu` | `sn` |
| MAC | `mac_cpe` (CPE), `mac_router_wifi` | `search_by_mac`, `get_onu_macs/{id}` |
| Identidad del abonado | `nombre`, `cedula`, `email`, `telefono`, `direccion`, `usuario` (PPPoE) | `name`, `address`, `zone_name` |
| Estado comercial | `estado`, `estado_facturas`, `saldo`, `fecha_corte`, `plan_internet`, `ip` | — |
| Estado óptico | — | `get_onu_status` (Online/LOS/Power fail/Offline), `get_onu_signal` (dBm 1310/1490, etiqueta Critical/Warning/Very good), `status_history` |
| Topología | `zona`, `router`, `sectorial` | `olt_id`, `olt_name`, `board`, `port`, `onu`, `odb_name` |
| ⚠ Secretos que **no se importan** | `password_servicio`, `password_cpe`, `password_router_wifi`, `password_ssid_router_wifi`, `usuario_router_wifi` | `username`, `password`, running-config |

**Hallazgo clave (FACT):** WispHub expone `sn_onu` y SmartOLT expone `sn` ⇒ existe una **clave de enlace determinística entre ambos orígenes** (serial de ONU), más estable que nombre o teléfono. **UNVERIFIED** que `sn_onu` esté poblado y con el mismo formato en la operación real de Terranet (hay que medir en sandbox).

## 2. Esquema propuesto (todas las tablas con `account_id`, índices explícitos, **sin FK de BD**, migraciones reversibles)

```
terranet_isp_subscribers            -- el abonado según el proveedor comercial (WispHub): 1 fila por cliente externo
  account_id, provider='wisphub', external_customer_ref (nullable), display_name_digest?, document_digest (HMAC),
  last_synced_at, source_updated_at, stale (bool), sync_error_code, timestamps
  UNIQUE (account_id, provider, external_customer_ref)

terranet_isp_services               -- N servicios por abonado (no se fuerza 1:1)
  account_id, subscriber_id, provider, external_service_id (WispHub id_servicio), plan_name, commercial_state,
  balance_cents (nullable), invoice_state, cutoff_date, onu_serial (normalizado), cpe_mac (normalizado),
  install_address_hash, last_synced_at, source_updated_at, stale, timestamps
  UNIQUE (account_id, provider, external_service_id); INDEX (account_id, onu_serial)

terranet_isp_onus                   -- estado óptico cacheado (SmartOLT)
  account_id, provider='smartolt', external_onu_id (unique_external_id), serial, olt_name, board, port, status,
  rx_dbm, tx_dbm, signal_label, signal_read_at (fecha de la LECTURA), status_changed_at, last_synced_at, stale, timestamps
  UNIQUE (account_id, provider, external_onu_id)

terranet_isp_customer_bindings      -- el vínculo contacto ↔ servicio (la verdad de Terranet; auditable)
  account_id, contact_id, service_id (→ terranet_isp_services), onu_id (nullable),
  state (candidate|confirmed|rejected|revoked), match_method, confidence (0–100, explicable), evidence jsonb (SIN PII en claro),
  proposed_by (system|user_id), verified_by_id, verified_at, revoked_by_id, revoked_at, reason, timestamps
  UNIQUE parcial (account_id, contact_id, service_id) WHERE state IN ('candidate','confirmed')

terranet_isp_conversation_snapshots -- qué datos ISP vio el agente en una conversación y con qué frescura
  account_id, conversation_id, binding_id, block, source, fetched_at, freshness, payload_digest, actor_id, created_at

terranet_isp_audit_events           -- (ver 07) vincular/desvincular/ver datos sensibles/rotar credenciales
```
- `contact_id`/`conversation_id` apuntan a tablas upstream **sin** FK de BD (política del repo); la integridad la mantienen asociaciones y callbacks propios.
- **No se copian** facturas completas, contraseñas, claves PPPoE, ni cuerpos de proveedor: solo los campos normalizados necesarios. Los datos externos siguen siendo propiedad de WispHub/SmartOLT y se refrescan; la tabla es **caché con trazabilidad**, no una réplica.
- PII (cédula, teléfono, dirección): digest (HMAC con clave de aplicación) cuando basta con **comparar**; en claro solo lo imprescindible para mostrar, con cifrado de columna si se persiste.

## 3. Identidad: reglas de vinculación

**Jerarquía de evidencia (de mayor a menor confianza):**
1. **Vínculo manual confirmado** por un agente autorizado (siempre prevalece; queda `verified_by`/`verified_at`).
2. **Claves externas estables:** `id_servicio` (WispHub) y `unique_external_id` (SmartOLT) ya conocidas por un vínculo previo.
3. **Serial de ONU** presente en ambos orígenes (`sn_onu` ↔ `sn`): enlaza **servicio ↔ ONU** de forma determinística.
4. **Documento (cédula)** exacto + teléfono: propone candidato; **no confirma solo**.
5. **Teléfono E.164** (+593…): señal auxiliar. **Nunca identificador único** (hogares con un teléfono compartido, números reasignados, varios servicios).
6. **Nombre/dirección**: solo desempate y explicación al revisor humano.

**Reglas duras (obligatorias, con tests):**
- **Nunca autovincular ante ambigüedad:** >1 candidato, claves contradictorias, teléfono compartido, documento duplicado, números cambiados o `stale` ⇒ estado `candidate`, lista de candidatos con **evidencia explicable** (qué coincidió y con qué peso) para revisión humana.
- Una confirmación automática solo se permitiría (fase posterior, con aprobación explícita) cuando coincidan **dos claves independientes** y no exista ningún conflicto; en el MVP **toda confirmación es humana**.
- Contacto con teléfono normalizado pero sin vínculo ⇒ el panel muestra "No vinculado" y los candidatos; **nunca** muestra datos de un abonado sin vínculo confirmado.
- Desvincular es un **evento** (`revoked`), no un borrado; se conserva historial y quién/cuándo/por qué.
- Un contacto puede tener **varios servicios**; un servicio puede tener varios contactos (familia); la UI lo representa sin colapsarlo.
- Normalización de teléfono a E.164 (Ecuador `+593`, quitando el 0 inicial) como función única y probada; el matching compara **normalizado**.

## 4. Panel de conversación "Terranet · Cliente ISP"
Ubicación: nueva sección arrastrable en `ContactPanel.vue` (precedente: Shopify/Stripe/Linear), alimentada por **API propia** con Pundit; **el navegador nunca llama a WispHub/SmartOLT** ni recibe JSON de proveedor.

Bloques y fuente (todos con `source`, `fetched_at`, `freshness` ∈ `live|cache|stale|unavailable`, `status`, `error`):
- **Vínculo:** vinculado/no vinculado/candidatos, quién confirmó y cuándo.
- **Servicio:** plan, estado comercial, fecha de corte, IP técnica *(según permiso)*.
- **Facturación:** saldo/mora/último estado *(solo roles autorizados)*.
- **Red:** estado ONU (Online/LOS/Power fail/Offline), señal **con la fecha de la lectura**, OLT/PON, historial de estado. Semáforo **solo** con dato verificado y umbrales configurables; sin dato fresco ⇒ gris "sin dato", **nunca** verde por defecto.
- **Soporte:** conversaciones previas del contacto, notas, tickets (WispHub, lectura), responsables.
- Enlaces de contexto a las fuentes (p. ej. la URL directa de SmartOLT a la ONU documentada por el proveedor).

**Respeto de los límites de SmartOLT (FACT, `07` §3):** el estado continuo llega por **eventos SSE/webhook**; la señal óptica se pide **bajo demanda** (botón "Actualizar señal", un agente, una ONU), con caché y límite por ONU; **nada** de sondeo masivo ni bucles.

## 5. Trazabilidad conversación ↔ datos ISP
- Cada vez que un agente abre el bloque, se guarda un **snapshot mínimo** (qué bloque, de qué fuente, con qué frescura, hash del contenido) asociado a conversación, vínculo y agente — sin copiar el contenido sensible a mensajes.
- Cambios de estado relevantes (vínculo, corte/reactivación observados, caídas PON) alimentan la línea de tiempo del abonado (M7).
- Nunca se inserta PII, saldo ni credenciales en el cuerpo de un mensaje ni en notas automáticas.

## 6. Aislamiento y seguridad
- `account_id` en **toda** tabla, consulta, job y caché Redis (`terranet:isp:{account_id}:…`); scopes por defecto en los modelos propios.
- API del panel: Pundit por recurso; pruebas **IDOR** (agente de otra cuenta, conversación ajena, binding ajeno), **elevación** (agente intentando confirmar/ver facturación sin rol) y enmascarado por rol (cédula, teléfono, dirección, saldo).
- Normalizadores con **lista blanca**; test que falla si un campo no listado (`password*`, `usuario_*`, `username`, running-config) llega a la capa de persistencia o al JSON del panel.
- Logs/auditoría sin tokens ni PII; retención definida por política Terranet (pendiente).

## 6.1 Riesgos y casos límite a cubrir con fixtures
Teléfono compartido por dos abonados · abonado con 3 servicios · cambio de número · ONU reemplazada (serial nuevo, mismo servicio) · `sn_onu` vacío · cédula duplicada · datos `stale` tras caída del proveedor · 429 de SmartOLT en medio de una consulta · servicio cancelado (`fecha_cancelacion`) · contacto sin teléfono (canales no WhatsApp).

## 7. Fases
| Fase | Entrega | Aceptación |
|---|---|---|
| M5.0 (esta) | modelo + reglas + panel (diseño) | revisión del propietario |
| M5.1 | tablas + adaptadores `Fake` + API del panel con datos sintéticos | specs de matching (todos los casos de §6.1), IDOR/elevación, lista blanca, freshness; sin red |
| M5.2 | vinculación manual en Super Admin + UI del panel | confirmación humana auditada; no autovincula |
| WispHub/SmartOLT reales | solo con staging autorizado | ver `07` §10 |

## 8. Decisiones pendientes del propietario
1. Qué roles ven **facturación** e **IP técnica** (propuesta: administradores y agentes de soporte designados; agentes generales solo estado y plan).
2. Umbrales del semáforo óptico (RX en dBm) y de mora.
3. Si se permitirá, en una fase posterior, la **confirmación automática** con dos claves independientes (por defecto: **no**).
4. Retención de snapshots y auditoría.
