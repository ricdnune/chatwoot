# 10 — M3.1 Branding Terranet: changelog, evidencia y reversión

Rama `terranet/feature/m3-branding` (pila: `m0-m1-baseline-lab` → `m2-privacy-egress` → `m3-0-governance` → `m3-branding`). Base `v4.19.1`. Edición Community. Laboratorio local; **producción intacta**.
Convención: **FACT** · **PENDING** (necesita validación del propietario).

## 1. Qué cambió (FACT)

| # | Cambio | Archivos | Nivel |
|---|---|---|---|
| 1 | Logo, insignia oscura, isotipo y juego completo de iconos generados **del logo original** | `terranet/branding/{build_assets.py,source/*}`, `public/brand-assets/terranet/*`, 31 PNG en `public/` (mismos nombres) | T2 + assets |
| 2 | Tarea **idempotente y con lista blanca** que aplica el branding a `installation_configs` (`rails terranet:branding:apply|status|revert`, `DRY_RUN=1`) | `config/terranet/branding.yml`, `lib/terranet/branding.rb`, `lib/tasks/terranet/branding.rake` | T2 |
| 3 | Super Admin muestra el nombre y los logos configurados (con **respaldo a los valores upstream**) y conserva "Chatwoot vX.Y.Z" como motor | `app/views/super_admin/application/{_brand,_standalone}.html.erb`, `app/views/layouts/super_admin/application.html.erb` | T3 (3 vistas MIT) |
| 4 | Color de tema/tile del navegador `#2D2DBA` (medido del logo original) y nombre/colores del manifiesto PWA | `app/views/layouts/vueapp.html.erb` (2 líneas), `public/manifest.json` | T3 |
| 5 | `lab.sh up` aplica el branding (idempotente) | `terranet/lab/lab.sh` | T2 |
| 6 | Specs (13 ejemplos) | `spec/lib/terranet/branding_spec.rb` | T2 |

No se tocó `enterprise/`, no se editó ningún archivo i18n ni se hizo búsqueda/reemplazo global de "Chatwoot".

## 2. Valores aplicados (`config/terranet/branding.yml`)
`INSTALLATION_NAME=Terranet`, `BRAND_NAME=Terranet`, `LOGO=/brand-assets/terranet/logo.png`, `LOGO_DARK=/brand-assets/terranet/logo_dark.png`, `LOGO_THUMBNAIL=/brand-assets/terranet/logo_thumbnail.png`, `BRAND_URL=WIDGET_BRAND_URL=https://terranet.com.ec` (**PENDING:** suposición a confirmar). `DISPLAY_MANIFEST`, `TERMS_URL`, `PRIVACY_URL` no se tocan (los dos últimos solo se usan en el registro, deshabilitado).

## 3. Activos y su origen (honestidad sobre lo provisional)
- Fuente: `terranet/branding/source/terranet-logo-original.png` — copia **byte a byte** de `~/Projects/terranet-gpon-olt/brand/terranet-logo-original.png` (793×265, RGBA con fondo blanco opaco). SHA-256 `8a26fd237cc778bdb791297767db83c30ec9238a6760d8d982c6dd150fcde8a6` (`source/SHA256`; el generador **aborta** si cambia).
- **No se vectorizó, recoloreó ni deformó.** Operaciones: (1) transparencia por alfa por píxel contra el color de relleno plano de cada glifo (los colores medidos `#2D2DBA` y `#0098F7` se conservan exactos), (2) recorte, (3) píxeles intactos sobre insignia/cuadro blanco donde hace falta fondo claro, (4) remuestreo Lanczos. La "T" con ala se aísla como **componentes conexos propios** del bitmap original (ningún píxel de la "e").
- **PROVISIONAL:** el isotipo se ampliaba desde ~200 px (los iconos grandes se ven suaves); no existe vector oficial ni versión para fondo oscuro. Tema oscuro = el logo sobre insignia blanca (el índigo no es legible sobre `#1b1c1d`).
- Los otros archivos locales (`terranet-logo.svg`, `terranet-logo.png` recoloreado, `favicon.*`) **no se usaron**: no consta que sean oficiales.
- **PENDING del propietario:** SVG/AI oficial, variante oscura, isotipo, paleta y tipografía (ver `02`). Cuando existan, basta reemplazar los archivos de `public/brand-assets/terranet/` y regenerar el juego de iconos.

## 4. Consecuencias que conviene que el propietario revise antes de producción (PENDING)
1. **Widget y Help Center públicos:** `BRAND_NAME`/`WIDGET_BRAND_URL`/`LOGO_THUMBNAIL` alimentan también el pie "Powered by" del widget de chat y de los portales, y los pies de los correos. Con estos valores dicen **"Terranet"** (enlace a `BRAND_URL`) en vez de Chatwoot. Es el comportamiento estándar de esos ajustes, pero **retira la atribución visible a Chatwoot en esas superficies públicas**; se mantiene en el repositorio, `LICENSE` y Super Admin. Confirmar con asesoría legal/de marca antes de aplicar en producción. (Reversible con `terranet:branding:revert`.)
2. **Acento de la interfaz:** el azul de botones/enlaces sigue siendo el de Chatwoot (`#2781F6`); no se cambió porque la paleta oficial no está confirmada. `theme-color` y manifiesto usan el índigo del logo.
3. **Aplicar en producción** es una **acción humana**: `rails terranet:branding:status` → `apply` (con `DRY_RUN=1` primero) tras backup; este trabajo no la ejecuta.
4. Los favicons dependen de archivos estáticos con nombres fijos en `public/`; un upgrade de Chatwoot que cambie esos binarios generaría conflicto trivial (se resuelve regenerando con el script).

## 5. Evidencia (laboratorio, `docs/terranet/evidence/m3/`)
| Antes | Después |
|---|---|
| `before-login-light-desktop.jpg`, `before-login-dark-desktop.jpg` | `after-login-light-desktop.jpg`, `after-login-dark-desktop.jpg`, `after-login-light-mobile.jpg` |
| `before-dashboard-light-desktop.jpg` | `after-dashboard-light-desktop.jpg`, `after-dashboard-dark-desktop.jpg`, `after-dashboard-menu-mobile.jpg` |
| `before-superadmin-dashboard.jpg` | `after-superadmin-login.jpg`, `after-superadmin-dashboard.jpg` |
| — | `after-email-password-reset.jpg` (correo en Mailpit), `after-favicon-set.png` (iconos 16/32/96, insignia de no leídos, Apple/Android) |
Los "antes" se capturaron con la tarea `terranet:branding:revert` (retirada en M3.2, ver §7) (equivalente actual: `reset_to_upstream_defaults`; prueba de que se restaura la apariencia upstream) y los "después" tras `apply`. Datos 100 % sintéticos del seed.

## 6. Pruebas (comandos y resultados, 2026-10-27)
Ver el reporte final y `03` §5. Resumen: specs de branding 13/0 fallos; Super Admin 151+8 ejemplos/0 fallos; FOSS (sin `enterprise/`) 363/0; Vitest 1 672/0 (no se cambió JS); `audit-egress` PASS tras el cambio; todas las pantallas cargan solo desde `127.0.0.1:13000` (sin recursos externos).

## 7. Reversión (corregida en M3.2)
`revert` restauraba siempre los valores de upstream, lo que **destruía personalizaciones previas** de una instalación real. Se sustituye por dos operaciones distintas:

| Tarea | Qué hace | Cuándo usarla |
|---|---|---|
| `rails terranet:branding:apply` | Antes de la **primera** escritura guarda una instantánea de las 7 claves (presente/ausente + valor exacto) y aplica los valores Terranet. Idempotente; todo o nada (transacción con bloqueo de filas; si falla se deshace todo y se borra la instantánea creada en esa ejecución). | Despliegue de la marca |
| `rails terranet:branding:restore` | Devuelve **exactamente** lo que había antes del primer `apply`: restaura valores, recrea claves que existían y **elimina** las que no existían. Sin instantánea aborta con error (no adivina valores). Tras restaurar archiva la instantánea (`…restored-<UTC>.json`). | Rollback real |
| `rails terranet:branding:reset_to_upstream_defaults` | Escribe los valores por defecto de `config/installation_config.yml`. **No** es "volver al estado anterior". | Dejar la instalación en blanco upstream, a propósito |
| `rails terranet:branding:status` | Actual vs deseado y presencia de la instantánea. | Auditoría |

`DRY_RUN=1` está disponible en `apply`, `restore` y `reset_to_upstream_defaults` al ejecutar `rails` directamente (el wrapper `lab.sh` no reenvía variables de entorno al contenedor; la ruta de dry-run está cubierta por specs).

**Instantánea:** `tmp/terranet/branding_backup.json` (ignorada por git, modo `0600`, directorio `0700`, escritura atómica, nunca se sobrescribe una instantánea existente). Solo contiene las 7 claves de marca (nombres y URLs públicas, ningún secreto). En contenedores `tmp/` es efímero: fijar `TERRANET_BRANDING_BACKUP=/ruta/en/volumen/persistente/branding_backup.json` **antes** del primer `apply` en cualquier despliegue real y conservar el archivo hasta confirmar la marca. Si se pierde la instantánea no hay forma de reconstruir los valores originales desde el sistema.

Una instantánea manipulada (clave fuera de la lista blanca, clave ausente, entrada mal formada) se rechaza.

**Pruebas (24 ejemplos, 0 fallos):** apply → restore exacto con valores personalizados; claves previamente ausentes; la instantánea original sobrevive a `apply` repetidos y a un reset; permisos `0600`; dry run sin escritura ni instantánea; fallo a mitad de `apply` (sin cambios ni instantánea) y a mitad de `restore` (sin cambios, instantánea intacta); instantánea manipulada; restore sin instantánea. Demostración manual en el laboratorio: instalación con `INSTALLATION_NAME=Acme Demo` y sin `BRAND_URL` → `apply` → `restore` devuelve `Acme Demo` y elimina `BRAND_URL`.

**Código:** `git revert` de los commits de la rama (los iconos vuelven con `git checkout v4.19.1 -- public/*.png`); las vistas de Super Admin ya caen a los valores upstream si la configuración está vacía.
