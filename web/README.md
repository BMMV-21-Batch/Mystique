# web/

Vite + React 18 + TypeScript PWA, hosted on Cloudflare Pages. Spec §12–§14.

Owners: stream B (user flow) and stream C (admin & dev). The scaffold is task **B-01**: until it lands, this folder is only the layout below.

```
src/
  routes/
    user/        /, /login, /buy, /orders, /tickets       (B)
    admin/       /admin/*, /admin/mfa                     (C)
    dev/         /dev/*                                   (C)
    scan/        /admin/scan (R2, Dec)                    (G)
  components/    shared UI
  lib/           Supabase client (+ x-request-id), API wrappers, error-code mapper, formatters
  i18n/          en.json, si.json, index.ts               (D-04)
  pwa/           service worker config                    (D-13)
public/
  fonts/         subsetted Noto Sans Sinhala              (D-05)
  _headers       security headers / CSP                   (D-12)
```

Rules: no secrets except the public Supabase key; no `dangerouslySetInnerHTML`; every user-facing string goes through i18n.
