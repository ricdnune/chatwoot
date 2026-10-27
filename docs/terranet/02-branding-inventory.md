# 02 — Inventario de branding (M3 preparatorio; no se ha modificado ningún activo ni código)

Convención: **FACT** (verificado) · **INFERENCE** · **DECISION**. Base: `terranet/main` = `v4.19.1`.

## 1. Estado de los activos reales de Terranet

Búsqueda de solo lectura en `~/Projects` (no se copió nada al repo todavía). Aparecen los mismos archivos duplicados en `terranet-gpon-olt/brand/`, `tn-wt-admin/brand/` y copias en `frontend/public` / `dist` (hashes idénticos entre proyectos).

| Archivo (relativo a `~/Projects/terranet-gpon-olt/brand/`) | Dimensiones | Observación (FACT medido) |
|---|---|---|
| `terranet-logo-original.png` | 793×265, RGBA | Logotipo con ala sobre la "T". Colores medidos: índigo `#2D2DBA`, azul `#0098F7`. **Fondo blanco opaco** (no transparente) → no sirve tal cual sobre modo oscuro ni sobre colores |
| `terranet-logo.png` | 1000×282, RGBA | Variante **recoloreada** (azules `#2955A1` / `#06A8FD`) y reescalada: no coincide con el original |
| `terranet-logo.svg` | viewBox 340×100, 1 076 B | **INFERENCE:** reconstrucción manual (paths simples y comentarios como "Wing feathers left", fill `#3131B5`), no un vector oficial |
| `favicon.png/.ico/.svg` | — | Existen; origen/oficialidad **no verificados** |

**⚠ Bloqueante para M3:** el prompt prohíbe usar un logo inventado o generado. De lo hallado solo `terranet-logo-original.png` parece el logotipo auténtico, y es de baja calidad para este uso (raster, fondo blanco). **No se integra ningún activo hasta que Terranet confirme cuál es oficial.**

### Lo que hay que pedir a Terranet (lista exacta)

1. Logotipo oficial vectorial (SVG/AI/PDF/EPS) o PNG ≥ 2000 px de ancho con **fondo transparente**.
2. Variante para **modo oscuro** (o confirmación de que se usa una versión monocroma blanca autorizada).
3. Isotipo/símbolo cuadrado (la "T" con ala) para favicon, PWA y avatar; mínimo 1024×1024 transparente.
4. Paleta oficial (HEX/Pantone) y tipografía; guía de uso mínimo (márgenes, tamaño mínimo).
5. Confirmación de cuál de los archivos de §1 es el oficial.
6. Dominios/URLs de marca: sitio, soporte, términos y privacidad (`BRAND_URL`, `TERMS_URL`, `PRIVACY_URL`).

## 2. Puntos de branding en Chatwoot (FACT, archivos inspeccionados)

### 2.1 Configuración centralizada (T1)
`config/installation_config.yml` (bloque "Branding Related Config"): `INSTALLATION_NAME` (`Chatwoot`), `LOGO_THUMBNAIL` (`/brand-assets/logo_thumbnail.svg`, 512×512 favicon), `LOGO`, `LOGO_DARK`, `BRAND_URL`, `WIDGET_BRAND_URL`, `BRAND_NAME`, `TERMS_URL`, `PRIVACY_URL`, `DISPLAY_MANIFEST`.
`GlobalConfig` lee **Redis → tabla `installation_configs`** (`lib/global_config.rb`): **no hay precedencia por variable de entorno** para estas claves; el `.yml` solo siembra valores en instalaciones nuevas (un Chatwoot de producción ya sembrado mantiene sus valores).

### 2.2 Activos estáticos (`public/`)
- `public/brand-assets/{logo,logo_dark,logo_thumbnail}.svg` — logo en dashboard/login/emails.
- `public/favicon-{16x16,32x32,96x96,512x512}.png`, `favicon-badge-*.png` (favicon con indicador), `android-icon-{36…192}.png`, `apple-icon-*.png`, `ms-icon-*.png`, `apple-touch-icon*.png` (**FACT:** `public/apple-touch-icon.png` pesa 0 bytes en upstream).
- `public/manifest.json` (PWA: `name`/`short_name` = "Chatwoot", iconos), `public/browserconfig.xml`, `public/sw.js`.
- `public/404.html`, `422.html`, `500.html` (páginas de error estáticas).

### 2.3 Plantillas y layouts
- `app/views/layouts/vueapp.html.erb`: `<title>` y `meta description` con `INSTALLATION_NAME`; bloque `DISPLAY_MANIFEST` (favicons + `manifest.json` + `theme-color #2781F6`, líneas 11–32).
- `app/views/widgets/show.html.erb`: título del widget; `disableBranding` (premium).
- `app/views/layouts/portal.html.erb` y `…/documentation_layout/_footer.html.erb`: footer del Help Center; se oculta con `disable_branding` (**premium**).
- Emails: `app/views/layouts/mailer/base.liquid` (usa `global_config['BRAND_NAME']`/`BRAND_URL`), `app/views/devise/mailer/*.erb`, `app/views/mailers/**`.
- Remitente por defecto: `config/initializers/devise.rb` → `MAILER_SENDER_EMAIL` por defecto `Chatwoot <accounts@chatwoot.com>` (se resuelve por variable de entorno).

### 2.4 Frontend (Vue)
- Logos: `components-next/icon/Logo.vue`, `shared/components/Branding.vue`, `v3/views/login/Index.vue`, `v3/views/login/Saml.vue`, `v3/views/auth/signup/Index.vue`, `components/widgets/conversation/OnboardingView.vue`, `modules/widget-preview/components/Widget.vue`, `shared/store/globalConfig.js`.
- Helper de marca: `shared/composables/useBranding.js` (`replaceInstallationName`) — **usar este** para textos con "Chatwoot" (indicación de `CLAUDE.md`).
- Tema: `tailwind.config.js` (colores) y `theme/`; el color primario por defecto es azul Chatwoot; los tokens deben ajustarse una vez confirmada la paleta.
- i18n: 54 apariciones de "Chatwoot" en `app/javascript/dashboard/i18n/locale/en/*.json`; **FACT:** existe el locale `es` pero no `es_EC`. Política del repo: solo se edita `en.yml`/`en.json`; otros idiomas vía Crowdin → para ES-EC propio habría que decidir entre (a) usar `es` y sobrescribir cadenas puntuales mediante `INSTALLATION_NAME`/`replaceInstallationName`, o (b) un parche T3 mantenido localmente (**DECISION pendiente**).

## 3. Plan de integración (cuando haya activos oficiales)

| Prioridad | Área | Cambio | Nivel |
|---|---|---|---|
| 1 | `public/brand-assets/*` | reemplazar SVG por los oficiales (misma ruta, sin tocar código) | T1/T3 (assets MIT) |
| 1 | Valores `INSTALLATION_NAME`, `BRAND_NAME`, `BRAND_URL`, `TERMS_URL`, `PRIVACY_URL` | ver §5 (licencia) | T1 |
| 2 | Favicons/iconos PWA + `manifest.json` | generar todos los tamaños desde el isotipo oficial | T3 |
| 2 | `vueapp.html.erb` (`theme-color`), `tailwind.config.js` | tokens de color Terranet | T3 |
| 3 | Emails (remitente, encabezado, invitaciones, password reset) | `MAILER_SENDER_EMAIL`, `BRAND_*` | T1 |
| 3 | Widget, Help Center, páginas 404/422/500 | por configuración de portal/inbox + assets | T1/T3 |
| 4 | Textos ES-EC | decisión §2.4 | T1/T3 |

Criterios de aceptación de M3: capturas en claro/oscuro, móvil/escritorio; contraste AA; sin referencias visibles a "Chatwoot" fuera de lo legalmente exigido; avisos de copyright/licencia intactos; PWA instalable con iconos nítidos.

## 4. Lo que NO se hace
- No se reemplaza "Chatwoot" por búsqueda global. No se generan logos. No se elimina el copyright ni los avisos de licencia.

## 5. ⚖ LICENSE FLAGS del branding (decisión humana pendiente)

1. **FACT:** en la edición comunitaria el Super Admin **no** ofrece la sección `custom_branding` (`app/controllers/super_admin/app_configs_controller.rb:59-80`); solo la ofrece el módulo Enterprise y únicamente con `pricing_plan != 'community'` (`enterprise/app/controllers/enterprise/super_admin/app_configs_controller.rb`).
2. **FACT:** `disable_branding` (quitar "Powered by Chatwoot" en widget/Help Center) es `premium: true` (`config/features.yml`).
3. **Por tanto:** escribir directamente filas de `installation_configs` por consola/seed para esquivar el candado de la UI **no se hará** sin decisión explícita: sería eludir un control de licencia premium.
4. Caminos legítimos a decidir:
   - **(A)** Adquirir la licencia/suscripción aplicable y usar `custom_branding` + `disable_branding` tal como están.
   - **(B)** Edición **solo MIT**: `DISABLE_ENTERPRISE=true` (interruptor oficial, `lib/chatwoot_app.rb:15`) y personalizar **archivos MIT** (valores por defecto en `installation_config.yml`, `public/`, layouts, Tailwind). *Pendiente de confirmar con asesoría legal* si el esquema "powered by" y las marcas permiten esa variante; la funcionalidad Enterprise (Captain, audit logs, SLA, custom roles…) quedaría desactivada.
5. Quitar branding visual permitido **no** equivale a retirar copyright/licencia. Marcas registradas de Chatwoot: investigación separada pendiente.
