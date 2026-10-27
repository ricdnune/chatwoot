# Registro de customizaciones Terranet sobre Chatwoot

Base: `terranet/main` = tag `v4.19.1` (`caab07a8f00032d5205b5a5d7e2eb0ba2f3d2d82`), `VERSION_CW=4.19.1`.
Niveles: **T1** configuración · **T2** extensión modular (archivos nuevos) · **T3** parche mínimo a archivo upstream · **T4** divergencia profunda (prohibida salvo autorización).

Regla de oro: si un cambio toca `enterprise/`, debe registrarse aquí con la marca **ENTERPRISE** y no se mergea sin decisión humana de licencia (ver `docs/terranet/00-repository-baseline.md` §5).

## Cambios registrados

| ID | Nivel | Rutas | Motivo | Owner | Riesgo diff/rebase | Tests | Cómo retirarlo |
|---|---|---|---|---|---|---|---|
| TN-001 | T2 | `terranet/lab/` (compose, `env.lab.example`, `lab.sh`, `dns-sink/`) | Laboratorio local aislado (M1), usa `docker/Dockerfile` oficial sin cambios | Terranet | Nulo: solo archivos nuevos | Smoke del lab (ver `01-local-development.md`) | Borrar el directorio |
| TN-002 | T3 | `.dockerignore` (+2 líneas: `terranet/lab/.env`) | Evitar que el `.env` del lab entre en el contexto de build (`.dockerignore` oficial solo excluye `.env` en la raíz) | Terranet | Bajo: añadido al final; conflicto trivial | `docker build` + comprobar que `.env` no está en la imagen | Quitar las 2 líneas si el lab se mueve fuera del repo |
| TN-003 | T2 | `docs/terranet/*`, `docs/upstream/*` | Documentación propia | Terranet | Nulo | — | Borrar |

## Cambios previstos (aún NO implementados)

| ID | Nivel | Rutas probables | Motivo | Notas de licencia |
|---|---|---|---|---|
| TN-P01 | T1 (+T3 si hace falta) | env `DISABLE_TELEMETRY`, `ENABLE_PUSH_RELAY_SERVER`; parche mínimo para llamadas del frontend a `hub.2.chatwoot.com` | M2 privacidad | Solo toca código MIT (`lib/chatwoot_hub.rb` es MIT; `enterprise/lib/enterprise/chatwoot_hub.rb` **no** se edita) |
| TN-P02 | T1/T3 | `config/installation_config.yml`, `public/brand-assets/`, `public/manifest.json`, iconos, `vueapp.html.erb` | M3 branding | **LICENSE FLAG:** la edición de `custom_branding` en Super Admin es Enterprise; `disable_branding` es premium. Decisión humana pendiente (opción A licenciar / B edición MIT) |
| TN-P03 | T2 | modelos/servicios/controladores/Vue nuevos bajo namespace `Terranet::` / `terranet/` | M4+ contexto ISP | Solo MIT; sin copiar código de `enterprise/` |
| TN-P04 | T3 | `app/controllers/webhooks/whatsapp_controller.rb`, `app/controllers/concerns/meta_token_verify_concern.rb` | Cerrar HMAC condicional de Meta (ver `03-privacy-egress-audit.md` §6) | Código MIT; proponer también a upstream |

## Procedimiento de actualización (resumen)

1. Detectar release estable upstream (tag) → leer changelog y avisos de seguridad → revisar cambios en `LICENSE`/`enterprise/LICENSE`.
2. Rama `terranet/release/<ver>-tn.<n>` desde `terranet/main`; merge/rebase **controlado** del tag; resolver conflictos contra esta tabla.
3. CI + laboratorio + migración ensayada sobre DB sintética; aprobación humana; backup/restore probado; despliegue gradual.
4. Al absorber upstream un equivalente de un parche T3, marcarlo aquí como *retirado* y eliminarlo.
