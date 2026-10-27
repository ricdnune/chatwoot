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
`./lab.sh rspec spec/controllers/webhooks/whatsapp_controller_hmac_spec.rb` → **11 ejemplos, 0 fallos, 1 pendiente (esperado)**.

| Caso | Resultado |
|---|---|
| Canal con secreto + firma válida sobre cuerpo crudo | 200, job encolado |
| Cuerpo alterado tras firmar | 401, sin job |
| Firma con otro secreto | 401 |
| Firma ausente | 401 |
| Firma sin prefijo `sha256=` | 401 |
| **CURRENT** — canal manual sin secreto, sin firma | **200 (aceptado)** |
| **CURRENT** — igual con `WHATSAPP_APP_SECRET` global | **200 (aceptado)** |
| **CURRENT** — igual con firma **falsa** | **200 (aceptado)** |
| **TARGET (M2.1)** — rechazar sin firma si hay secreto global | *pending* (falla hoy como se espera; si deja de fallar RSpec lo avisa) |
| **CURRENT** — API de inbox devuelve `api_key` y `app_secret` a administradores | confirmado |
| Agentes no reciben `provider_config` | confirmado |

Los ejemplos "CURRENT" fijan el comportamiento actual para detectar cambios (nuestros o de upstream); **no** significan que sea deseable.

## 5. Plan de mitigación **sin parche** (disponible hoy)
Solo aplicable con autorización y en staging: añadir el `app_secret` de la app de Meta de Terranet al `provider_config` de cada canal manual (vía consola o `PATCH` completo preservando las demás claves) y validar con un payload firmado de Meta. **UNVERIFIED** que la UI lo permita; hacerlo en producción es un cambio de configuración productivo → requiere aprobación y ventana.

## 6. Qué NO se hizo
Sin parche, sin cambios de configuración, sin tocar webhooks de Meta, sin número real, sin acceso a PVE01/PVE02.

## 7. Propuesta de misión M2.1 (separada)
**Alcance:** (1) parche T3 mínimo en `MetaTokenVerifyConcern`/`WhatsappController` (módulo `prepend` propio en `lib/terranet/`) que exija firma para todo `whatsapp_cloud` cuando exista un secreto utilizable (canal o global) y rechace con log accionable cuando no exista, tras una bandera `TERRANET_WHATSAPP_REQUIRE_SIGNATURE`; (2) redactar `provider_config` sensible en `_inbox.json.jbuilder` para administradores (booleanos `*_configured`); (3) cifrado de `provider_config` sensible (migración de datos con ensayo en DB sintética); (4) propuesta del cambio a upstream.
**Criterios de aceptación:** los 11 ejemplos de §4 pasan con el target activado (el `pending` se vuelve verde y se convierte en ejemplo normal); canales embedded y con secreto siguen funcionando; test de "configuración incompleta → 401 + log"; pruebas con firmas sintéticas de Meta; sin cambios en producción hasta aprobación humana y plan de rollback (apagar la bandera).
