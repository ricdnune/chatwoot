# 05 — Guardrails de HA / producción (solo documental, no operativo)

**Alcance:** criterios para analizar PVE01 / PVE02 / R2 **sin tocarlos**. Este documento no contiene acceso, credenciales ni comandos contra producción. Nada de lo descrito aquí se ha ejecutado contra `chatwoot.terranet.com.ec`.

Convención: **REPORTED** = lo que describió el operador (no verificado) · **FACT** = visto en este repo · **INFERENCE** · **DECISION** · **UNVERIFIED** = requiere evidencia que hoy no tenemos.

## 1. Lo que se sabe y lo que NO

| Afirmación | Estado |
|---|---|
| PVE01 y PVE02 corren el mismo stack | REPORTED |
| Base de datos "sincronizada" para HA | REPORTED — **UNVERIFIED** la tecnología (streaming replication, Patroni, repmgr, DRBD, rsync de volumen, dump/restore…) |
| Es activo-activo / activo-pasivo / failover automático | **UNVERIFIED** — no asumir ninguno |
| Archivos en Cloudflare R2 | REPORTED; el repo lo soporta vía Active Storage S3 (`ACTIVE_STORAGE_SERVICE`, `AWS_*`; `.env.example`) |
| RPO / RTO | **UNVERIFIED** — no hay valores medidos |
| Redis compartido o por nodo | **UNVERIFIED** |

**Regla:** hasta cerrar la sección 3 no se escribe "HA" en ningún documento, runbook ni comunicación; se usa "dos nodos con réplica reportada".

## 2. Riesgos concretos derivados del código (FACT/INFERENCE sobre este SHA)

1. **Escrituras en dos nodos (split-brain).** Chatwoot (Rails 7.2, `pg` 1.5.3) escribe en un único primario. Si ambos nodos aceptan escrituras sobre réplicas independientes, divergen conversaciones/mensajes. *INFERENCE:* sin fencing (STONITH/lease), una promoción incorrecta duplica IDs de secuencia y corrompe la reconciliación. → Exigir evidencia de **un solo primario** y mecanismo de fencing.
2. **Redis por nodo.** Sidekiq y ActionCable (tiempo real) usan Redis (`REDIS_URL`). *INFERENCE:* si cada nodo tiene su Redis, (a) los jobs en cola no migran con el failover, (b) los eventos websocket no cruzan nodos, (c) el cron de Sidekiq (`config/schedule.yml`) se ejecuta dos veces. Redis debe ser único (con Sentinel/replicación documentada) o el segundo nodo debe tener Sidekiq apagado hasta promoción.
3. **Jobs duplicados.** Dos procesos Sidekiq contra la misma cola procesan una vez cada job (correcto), pero dos Sidekiq contra Redis distintos con la misma DB procesan **dos veces** los programados y los reintentos. Riesgo directo: dos envíos de WhatsApp.
4. **Claves compartidas.** `SECRET_KEY_BASE` debe ser idéntica en ambos nodos (sesiones/cookies firmadas). Las claves `ACTIVE_RECORD_ENCRYPTION_*` también: `Channel::Whatsapp` cifra `business_management_token` solo `if Chatwoot.encryption_configured?` (`app/models/channel/whatsapp.rb:31`). Una clave distinta o ausente en el nodo promovido deja datos ilegibles. **Nunca** versionarlas; respaldarlas fuera de la DB.
5. **Migraciones.** Un nodo con imagen nueva y otro con imagen vieja contra la misma DB rompe. `db/schema.rb` está en `2026_10_19_143116`; muchas migraciones son irreversibles → ver §5.
6. **Adjuntos / R2.** *INFERENCE:* ambos nodos deben usar el mismo bucket, endpoint, claves y región; URLs firmadas dependen de la hora del nodo (NTP) y de la clave. CORS y lifecycle de R2 son configuración del bucket, no del repo. No tocar R2 productivo; validar compatibilidad solo con bucket aislado y credenciales restringidas **con autorización**.
7. **Webhooks de Meta.** Meta entrega a una URL; si el balanceo envía el mismo evento a nodos distintos y hay deduplicación local (lock en Redis, `Whatsapp::MessageDedupLock`), dos Redis → mensajes duplicados. Además véase `03-privacy-egress-audit.md` (HMAC condicional).
8. **Relojes.** Firmas, tokens y expiraciones asumen reloj coherente: NTP en ambos nodos.
9. **Storage local.** `docker-compose.production.yaml` monta `storage_data:/app/storage` (disco local) — si `ACTIVE_STORAGE_SERVICE=local` quedara activo en algún nodo, los adjuntos no son visibles en el otro. Producción debería usar solo R2.
10. **Imagen flotante.** El compose de producción del repo usa `chatwoot/chatwoot:latest`; nunca desplegar así. Pin por tag **y digest**.

## 3. Evidencia mínima a solicitar al operador (checklist, sin acceder)

Marcar solo con evidencia adjunta (salida de comando redactada, diagrama, runbook):

- [ ] Diagrama de red: balanceador/túnel Cloudflare → nodos; quién termina TLS; healthchecks usados.
- [ ] Tecnología de replicación PostgreSQL, versión, modo (sync/async), lag típico y máximo observado.
- [ ] Quién es el primario hoy y cómo se determina; procedimiento y automatismo de promoción.
- [ ] Mecanismo de **fencing** del primario anterior; prueba de que no puede volver a aceptar escrituras.
- [ ] Topología de Redis (único/por nodo/Sentinel), persistencia (AOF/RDB), contraseña rotada.
- [ ] Dónde corre Sidekiq (¿ambos nodos?, ¿colas?, ¿concurrencia?) y cómo se evita doble cron.
- [ ] Gestión de secretos: dónde viven `SECRET_KEY_BASE`, `ACTIVE_RECORD_ENCRYPTION_*`, claves R2/Meta; copia segura.
- [ ] Backups: tipo (lógico/físico/PITR), frecuencia, retención, **última restauración probada** (fecha y resultado).
- [ ] RPO/RTO objetivo y medido en el último simulacro.
- [ ] Configuración R2: bucket, endpoint, CORS, lifecycle, política de acceso, rotación de claves.
- [ ] Versión desplegada exacta (tag/digest) en cada nodo y cómo se sincroniza.
- [ ] Procedimiento de despliegue actual (¿simultáneo?, ¿orden?, ¿ventana?).

## 4. Criterios de aceptación antes de llamar "HA" a la plataforma

1. Un único primario demostrable; promoción probada en **staging aislado** con fencing verificado.
2. Redis y Sidekiq con topología documentada y probada (sin jobs duplicados tras failover).
3. Prueba de pérdida de nodo: RTO medido ≤ objetivo; RPO medido ≤ objetivo; sin pérdida de mensajes WhatsApp aceptados.
4. Restauración de backup en un entorno limpio verificada con checksums de datos y de adjuntos.
5. Claves y secretos idénticos y custodiados en ambos nodos (sin pasar por Git).
6. Runbook de rollback **forward-fix** (§5) revisado por una segunda persona.

## 5. Actualizaciones: PostgreSQL e imágenes

- **FACT:** `db/migrate` contiene 204 migraciones; muchas no son reversibles. Revertir la imagen **no** revierte el esquema.
- **DECISION (propuesta):** estrategia *forward-fix* — (1) backup consistente + PITR habilitado, (2) ensayo de la migración sobre DB **sintética** o restauración **sanitizada y autorizada**, (3) ventana de mantenimiento, (4) migración con un solo nodo activo y el otro detenido, (5) smoke tests, (6) solo entonces el segundo nodo con la **misma** imagen (compara digest), (7) si falla: corregir hacia adelante o restaurar el backup (el rollback de código solo es válido si la migración fue compatible hacia atrás).
- Nunca desplegar los dos nodos al mismo tiempo sin plan validado.
- CI no ejecuta migraciones en producción ni recibe secretos productivos.

## 6. Qué NO se hace desde este repo/laboratorio

Sin SSH/API/DB/panel hacia PVE01, PVE02 o `chatwoot.terranet.com.ec`; sin cambios de DNS, certificados, firewall, túneles Cloudflare ni replicación; sin R2 productivo; sin copias de la DB productiva al laboratorio.
