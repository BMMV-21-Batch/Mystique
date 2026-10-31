#!/usr/bin/env node
// Applies Supabase Auth settings to a hosted project via the Management API (D-02, D-07).
// Run by deploy.yml for staging/prod; can also be run locally with an .env file loaded.
//
// Env: SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF, SITE_URL, SMTP_USER, SMTP_PASS
//      EXTRA_REDIRECTS (optional, comma-separated)
// Flags: --dry-run   print the payload (secrets hidden) without applying it
//
// CAPTCHA is deliberately not managed here: it is switched on once the login page works.

import { readFileSync } from 'node:fs';

const env = (name, required = true) => {
  const v = process.env[name];
  if (required && !v) throw new Error(`missing env ${name}`);
  return v ?? '';
};

const ref = env('SUPABASE_PROJECT_REF');
const siteUrl = env('SITE_URL').replace(/\/$/, '');
const redirects = [`${siteUrl}/**`, ...env('EXTRA_REDIRECTS', false).split(',').map((s) => s.trim()).filter(Boolean)];

// Plain-http redirects (localhost dev servers) are for staging only. Fail rather than loosen prod.
const isStaging = /^https:\/\/[a-z0-9-]*staging[a-z0-9-]*\.pages\.dev$/.test(siteUrl);
const insecure = redirects.filter((r) => !r.startsWith('https://'));
if (insecure.length && !isStaging) {
  throw new Error(`refusing non-https redirects for ${siteUrl}: ${insecure.join(', ')}`);
}
const otpEmail = readFileSync(new URL('../supabase/templates/otp-code.html', import.meta.url), 'utf8');
const otpSubject = 'Mystique: ඔබගේ පිවිසුම් කේතය / Your sign-in code';

const payload = {
  site_url: siteUrl,
  uri_allow_list: redirects.join(','),

  // Email OTP: 6 digits, 10 minutes (spec §5.3, §15.3)
  external_email_enabled: true,
  disable_signup: false,
  mailer_otp_length: 6,
  mailer_otp_exp: 600,
  mailer_secure_email_change_enabled: true,
  mailer_subjects_magic_link: otpSubject,
  mailer_templates_magic_link_content: otpEmail,
  mailer_subjects_confirmation: otpSubject,
  mailer_templates_confirmation_content: otpEmail,

  // Gmail SMTP with an App Password (dedicated sending account)
  smtp_host: 'smtp.gmail.com',
  smtp_port: '465',
  smtp_user: env('SMTP_USER'),
  smtp_pass: env('SMTP_PASS'),
  smtp_admin_email: env('SMTP_USER'),
  smtp_sender_name: 'Mystique Tickets',
  smtp_max_frequency: 60, // seconds before the same address can get another email
  rate_limit_email_sent: 150, // per hour, project-wide; Gmail itself caps ~500/day

  // TOTP MFA for admins/devs (aal2 checked in SQL)
  mfa_totp_enroll_enabled: true,
  mfa_totp_verify_enabled: true,
};

const hide = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) =>
  [k, /pass|secret/.test(k) ? '<hidden>' : /templates_/.test(k) ? `<${v.length} chars>` : v]));

if (process.argv.includes('--dry-run')) {
  console.log(JSON.stringify(hide(payload), null, 2));
  process.exit(0);
}

const api = `https://api.supabase.com/v1/projects/${ref}/config/auth`;
const headers = { Authorization: `Bearer ${env('SUPABASE_ACCESS_TOKEN')}`, 'Content-Type': 'application/json' };

const res = await fetch(api, { method: 'PATCH', headers, body: JSON.stringify(payload) });
if (!res.ok) {
  console.error(`PATCH failed: ${res.status} ${(await res.text()).slice(0, 300)}`);
  process.exit(1);
}

// Read back and verify every non-secret field.
const live = await (await fetch(api, { headers })).json();
const mismatched = Object.keys(payload)
  .filter((k) => !/pass|secret/.test(k))
  .filter((k) => String(live[k]) !== String(payload[k]));
if (mismatched.length) {
  console.error(`Auth config applied but these fields differ: ${mismatched.join(', ')}`);
  process.exit(1);
}
console.log(`Auth config applied and verified for ${ref}: site ${siteUrl}, ${redirects.length} redirect(s), Gmail SMTP, 6-digit OTP / 10 min, TOTP on.`);
