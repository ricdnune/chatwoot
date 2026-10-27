# 09 — Gobierno de ramas, publicación segura y versionado Terranet (M3.0)

## 1. Reglas
- `develop` del fork = espejo de upstream (no se toca). `terranet/main` = línea estable propia (hoy == tag `v4.19.1`, `caab07a8f0`). **No hay push directo ni force-push a ninguna de las dos.**
- Todo cambio entra por ramas `terranet/feature/*` y PR hacia `terranet/main`, con revisión humana. Nunca se mergea sin aprobación.
- **Pila actual de ramas (cada una parte de la anterior):** `m0-m1-baseline-lab` → `m2-privacy-egress` → `m3-0-governance` → `m3-branding`. Los PR de la pila se revisan en ese orden; M2.1 (`m2-1-whatsapp-hmac`) es una rama **separada** que nunca se mezcla con branding.
- El fork `ricdnune/chatwoot` es **público** (verificado con `gh api`): todo lo que se publica es visible. Por eso: sin secretos, sin datos de clientes, sin dumps, sin `.env`. **Corrección (M4):** los documentos publicados antes de M4 (`05`, partes de `03` y `06`) **sí** nombran nodos y proveedores de producción; ver `11`. Desde M4 los documentos nuevos describen la infraestructura solo de forma genérica.
- `gh pr create` en un fork apunta por defecto al repositorio **upstream**: siempre usar `--repo ricdnune/chatwoot`.

## 2. Detección de secretos antes de publicar (fail-closed)
`terranet/tools/secret_scan.sh <rev-list>` ejecuta (1) **gitleaks** (imagen oficial, montaje de solo lectura) sobre el rango de commits, (2) comprueba que los valores secretos generados del lab (`terranet/lab/.env`) no aparecen en ningún commit, (3) prohíbe archivos `.env`, llaves, dumps. Cualquier hallazgo o falta de Docker ⇒ aborta (exit ≠ 0).
`terranet/tools/install_hooks.sh` activa `core.hooksPath=terranet/tools/hooks`: el hook `pre-push` escanea exactamente los commits que van a salir (`remote..local`, o `local --not --remotes` para ramas nuevas) y bloquea el push si hay hallazgos.
Limitaciones: gitleaks detecta patrones conocidos; no sustituye la revisión humana de documentos nuevos. Los activos de marca (logos) **sí** se publican (marca pública de Terranet); no se publican fotos/archivos de clientes.

### 2.1 Control de divulgación (M4) — además de gitleaks
gitleaks no detecta información de infraestructura que no sea un secreto. El hook `pre-push` ahora exige, por cada push:
1. `secret_scan.sh` (gitleaks + valores del lab + archivos prohibidos);
2. `disclosure_scan.sh`: sobre las **líneas añadidas** busca direcciones privadas fuera de los rangos del lab, correos, claves privadas, `ssh://`, tipos de archivo (`.pcap`, `.har`, `.sql`, `.dump`, `.log`, `.csv`…) y **cualquier patrón de `terranet/tools/disclosure_patterns.local`** (archivo **ignorado por git** con los nombres reales que nunca deben publicarse: nodos, hostnames, proveedores). Los specs y las líneas con `disclosure:ignore` (p. ej. la lista de bloqueo SSRF) se excluyen de los patrones genéricos;
3. **atestación humana:** tras leer el diff (documentos nuevos, imágenes de evidencia, hostnames, datos de clientes) se empuja con `TERRANET_DISCLOSURE_REVIEWED=1 git push …`. Sin esa variable el push se bloquea.
Es heurístico: no sustituye leer el diff. Validación: sobre el rango ya publicado `terranet/main..m3-branding` el escaneo con el denylist local **sí** detecta los hallazgos D1–D4 de `11`.

## 3. Versionado propio (futuro)
Etiqueta anotada `terranet-v<versión-chatwoot>.<N>` (p. ej. `terranet-v4.19.1.1`) sobre un commit de `terranet/main` tras PR aprobado. Cada etiqueta documenta: **SHA base** (tag upstream), **SHA derivado**, resultado de pruebas (§4) y hash/digest de la imagen. Nunca se despliega `latest`. Un upgrade usa la rama `terranet/upgrade/vX.Y.Z` (diff de parches T3 contra `docs/upstream/chatwoot-customizations.md`).

## 4. Registro de punto de control (2026-10-27)
| Elemento | Valor |
|---|---|
| Base upstream | tag `v4.19.1` → `caab07a8f00032d5205b5a5d7e2eb0ba2f3d2d82` |
| Cabeza M2 verificada | `585e18b350` (coincide con el reporte M2; árbol limpio; 30 archivos vs `v4.19.1`, solo 4 archivos upstream tocados: `.dockerignore`, `lib/chatwoot_hub.rb`, `avatar_from_favicon_job.rb`, `onboarding/index.html.erb`) |
| Secret scan `v4.19.1..585e18b350` | gitleaks: 5 commits, 0 hallazgos; valores del `.env` del lab: 0 coincidencias; patrones genéricos: 0 |
| `terranet/main` | Publicada en `origin` el 2026-10-27 en `caab07a8f0…` (== `v4.19.1`, verificado con `git ls-remote`); sin commits de features |
| Ruleset `terranet-main-protection` (id `25993578`, activo) | `deletion`, `non_fast_forward` (sin borrado ni force-push) y `pull_request` (PR obligatorio, 0 aprobaciones requeridas porque hay un único colaborador, hilos resueltos, descarta aprobaciones obsoletas) sobre `refs/heads/terranet/main` |
| Pendiente de configurar | Checks de estado requeridos (no hay CI en el fork: sin workflows que referenciar) y revisiones con ≥1 aprobación (necesita un segundo revisor). `develop` y la rama predeterminada **no** se tocaron |
| Modo Community validado | `./lab.sh foss-check` (copia **sin** `enterprise/`): arranque OK, correo de confirmación OK, specs verdes (ver `03` §7) |
