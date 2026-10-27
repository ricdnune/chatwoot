# 06 — WhatsApp Cloud: diagnóstico de verificación HMAC de webhooks (M2, investigación)

Base `v4.19.1`. **Solo diagnóstico y pruebas sintéticas.** No se cambió ningún webhook, canal ni código de producción; no se usó número real ni tráfico de Meta. Cualquier parche se propone como **misión M2.1** (§7).
Convención: **FACT** (código/ejecución) · **INFERENCE** · **UNVERIFIED**.

## 1. Cómo verifica hoy el código (FACT)
`app/controllers/webhooks/whatsapp_controller.rb` + `app/controllers/concerns/meta_token_verify_concern.rb`:
- `POST /webhooks/whatsapp/:phone_number` ejecuta `verify_meta_signature!`.
- La firma se calcula sobre el **cuerpo crudo** (`request.raw_post`) con `OpenSSL::HMAC.hexdigest('SHA256', secret, body)`, prefijo `sha256=` y comparación en tiempo constante (`ActiveSupport::SecurityUtils.secure_compare`). Cabecera `X-Hub-Signature-256`.
- Secretos candidatos: los del canal (`provider_config` claves `app_secret | app_secret_key | api_secret | client_secret`, o `channel.app_secret` si existe) **más** `WHATSAPP_APP_SECRET` global.
- **¿Es obligatoria?** `meta_signature_verification_required?` (`whatsapp_controller.rb:45-52`):
  - canal no encontrado → **sí** (rechaza);
  - canal no `whatsapp_cloud` (p. ej. 360dialog) → **no**;
  - canal `whatsapp_cloud` con secreto propio en `provider_config` → **sí**;
  - canal `whatsapp_cloud` con `source == 'embedded_signup'` → **sí**;
  - **cualquier otro `whatsapp_cloud` (p. ej. `manual_setup_v2`) → NO.**
- `GET /webhooks/verify` (suscripción de Meta) valida `hub.verify_token` contra `provider_config['webhook_verify_token']` (comparación con `==`, no en tiempo constante).

## 2. Hallazgos
| # | Hallazgo | Evidencia |
|---|---|---|
| R1 | **Un canal manual (`manual_setup_v2`, el que crea `Whatsapp::ManualSetupService`) no tiene `app_secret` en `provider_config` y por tanto el webhook se acepta sin firma.** | `manual_setup_service.rb:36-43` crea `provider_config {api_key, phone_number_id, business_account_id, source}`; spec propio (§4) |
| R2 | **Una firma falsa también se acepta** en ese tipo de canal: al no exigirse verificación, la cabecera ni se mira. | spec "CURRENT: accepts a payload carrying a forged signature" |
| R3 | El secreto global `WHATSAPP_APP_SECRET` **no** activa la exigencia para canales manuales. | spec "…even when WHATSAPP_APP_SECRET is configured globally" |
| R4 | **No hay campo en la UI/API de setup manual para el app secret** (búsqueda sin resultados en `app/javascript/.../inbox` y en el servicio). Solo se podría fijar vía `PATCH` del `provider_config` completo (riesgoso: reemplazo total) o consola. | grep + `Channel::Whatsapp::EDITABLE_ATTRS` |
| R5 | `provider_config` es `jsonb` **en claro**: `api_key` (token de acceso), `webhook_verify_token`, `app_secret`. Solo `business_management_token` se cifra (`app/models/channel/whatsapp.rb:31`, y solo `if Chatwoot.encryption_configured?`). Quedan en claro en la DB, en réplicas y en backups. | modelo + esquema |
| R6 | **La API de inbox devuelve `provider_config` completo a administradores** (`app/views/api/v1/models/_inbox.json.jbuilder:147`), incluidos token y app secret; a agentes no. | spec "CURRENT: returns the full provider_config … to administrators" y "does not return … to agents" |
| R7 | Logs: `filter_parameter_logging.rb` filtra claves que contengan `secret`, `_key`, `token`, `access`, etc. en **parámetros de petición**; no se verificó la redacción en cuerpos de respuesta, Sentry ni backups. | `config/initializers/filter_parameter_logging.rb`; resto **UNVERIFIED** |
| R8 | Que la verificación esté deshabilitada para canales 360dialog (`provider != whatsapp_cloud`) es intencional upstream; Terranet usa Cloud API oficial, no aplica. | código |

**Impacto (INFERENCE):** quien conozca el número de teléfono del canal y un `phone_number_id` (datos poco secretos) podría forjar mensajes entrantes y disparar flujos del agente/automatizaciones; el cuerpo forjado llega a `Webhooks::WhatsappEventsJob`. Riesgo mitigado solo por la oscuridad de la URL.

## 3. Qué haría falta para exigir HMAC-SHA256 de forma segura
1. **Sobre el cuerpo original**: ya se hace (`raw_post`); no reserializar JSON.
2. **Gestión del `app_secret`**: es el secreto de la **app de Meta** que posee el token del canal. Dos casos: (a) canales creados por Embedded Signup → app global (`WHATSAPP_APP_SECRET`, ya exigida); (b) canales manuales con la app propia de Terranet → secreto por canal o un único secreto de la app de Terranet. **DECISION propuesta:** secreto de app de Terranet en configuración global dedicada (p. ej. `WHATSAPP_APP_SECRET` si Terranet usa una sola app) y, si hay varias apps, secreto por canal en `provider_config`.
3. **Configuración incompleta = rechazar, no aceptar**: si hay canal `whatsapp_cloud` sin ningún secreto utilizable, rechazar (401) y registrar un error claro, en lugar de omitir la verificación. *Riesgo de compatibilidad:* canales manuales existentes dejarían de recibir hasta configurar el secreto → **migración con aviso previo** y bandera de transición.
4. **Rechazo de firma ausente/ inválida/ con prefijo erróneo / cuerpo alterado**: ya cubierto por tests cuando hay secreto (§4).
5. **Almacenamiento**: cifrar `app_secret`/`api_key`/`webhook_verify_token` en reposo (Active Record Encryption ya configurable: `ACTIVE_RECORD_ENCRYPTION_*`; requiere migración de datos y claves idénticas en ambos nodos, ver `05`), redactar en la API de inbox (devolver solo `…last4` o booleano "configurado"), y revisar backups/logs.
6. **No romper WhatsApp**: probar con tráfico sintético firmado y, solo con autorización, con un número de pruebas de Meta en staging aislado.

## 4. Pruebas (sintéticas) — `spec/controllers/webhooks/whatsapp_controller_hmac_spec.rb`
**M2.1 implementado en la rama `terranet/feature/m2-1-whatsapp-hmac` (solo laboratorio; no desplegado).** `./lab.sh rspec spec/controllers/webhooks spec/services/whatsapp spec/models/channel/whatsapp_spec.rb spec/lib/terranet` → **516 ejemplos, 0 fallos**; el spec HMAC: **14 ejemplos, 0 fallos**. Prueba de mutación: sin el `prepend` fallan **4** ejemplos; restaurado, 0.

| Caso | Resultado con M2.1 |
|---|---|
| Canal con secreto propio + firma válida sobre cuerpo crudo | 200, job encolado |
| Cuerpo alterado tras firmar / otro secreto / firma ausente / sin prefijo `sha256=` | 401 |
| **Canal manual sin secreto propio, sin firma, sin ningún secreto configurado** | **401** + log accionable `no Meta app secret configured` |
| Canal manual, sin firma, con `WHATSAPP_APP_SECRET` global | **401** (antes 200) |
| Canal manual, firma **falsa**, con secreto global | **401** (antes 200) |
| Canal manual firmado con el secreto global (una sola app de Meta, caso Terranet) | 200 |
| Canal manual, cuerpo alterado tras firmar con el secreto global | 401 |
| `TERRANET_WHATSAPP_REQUIRE_SIGNATURE=false` (**rollback solo lab/staging**) | restaura el comportamiento upstream (200 sin firma) |
| Canal 360dialog (otro proveedor) | sin cambios (200 sin firma) |
| API de inbox devuelve `api_key` y `app_secret` a administradores / no a agentes | confirmado (sin cambios; ver §7) |

**Specs upstream:** de los specs existentes solo **uno** contradice el endurecimiento por diseño —`spec/controllers/webhooks/whatsapp_controller_spec.rb:204` *skips signature validation for manual whatsapp cloud channels without an app secret*—; no se edita ni se borra: `spec/support/terranet/whatsapp_upstream_compat.rb` lo ejecuta en modo compatibilidad upstream (rollback activo solo para ese ejemplo). Los demás ejemplos upstream de webhooks pasan sin cambios (embedded signup, secreto de canal, secreto global sin canal, 360dialog, números inactivos).

## 5. Mitigación sin parche (descartada como solución final)
Añadir el `app_secret` al `provider_config` de cada canal manual por consola/PATCH completo es frágil (sin campo en la UI, reemplazo total del hash). M2.1 hace que el secreto global de la app de Meta basta para los canales manuales.

## 6. Qué NO se hizo
Sin cambios de configuración en producción, sin tocar webhooks de Meta, sin número real, sin acceso a PVE01/PVE02, **sin desplegar**.

## 7. Implementación (M2.1) y trabajo pendiente (M2.2)
**Implementado (T2 + 1 inicializador, sin editar archivos upstream de producción):** `lib/terranet/whatsapp.rb` (bandera segura por defecto), `lib/terranet/whatsapp_signature_policy.rb` (`prepend` sobre `Webhooks::WhatsappController`: firma obligatoria para todo `whatsapp_cloud`; sin secreto utilizable ⇒ rechazo con log; el HMAC y la comparación en tiempo constante son los de upstream), `config/initializers/terranet_whatsapp_signature.rb` (`to_prepare`).
**Requisito operativo antes de usar Meta en un despliegue nuevo:** configurar `WHATSAPP_APP_SECRET` (Super Admin → página `whatsapp_embedded`, disponible en Community) o `app_secret` por canal, **antes** de apuntar el webhook de Meta; de lo contrario el canal manual devolverá 401 por diseño. Validar en staging con payloads sintéticos firmados y, con autorización, un número de pruebas de Meta.
**Pendiente M2.2 (no incluido aquí):** (a) redactar `provider_config` en `_inbox.json.jbuilder` para administradores (la UI de edición de canal puede depender de esos valores → requiere análisis del frontend), (b) cifrado en reposo de `api_key`/`webhook_verify_token`/`app_secret` con migración de datos ensayada en DB sintética, (c) comparación en tiempo constante del `webhook_verify_token`, (d) rotación de secretos, (e) revisión de logs/backups, (f) proponer el cambio a upstream. **Aceptación M2.1:** los 14 ejemplos del spec HMAC verdes con el modo seguro como predeterminado (✔ en lab); canales embedded y con secreto siguen funcionando (✔); rollback documentado (✔).
