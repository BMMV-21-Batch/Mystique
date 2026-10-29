#!/usr/bin/env node
// Writes the Vault secrets the send-notifications cron job reads (migration 008, SD-15).
// Run by deploy.yml for staging/prod, after migrations. Idempotent: creates each secret once,
// updates it only when the value changed, then reads back and verifies (values never printed).
//
// Env: SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF, CRON_SECRET
// The same CRON_SECRET is given to the Edge Functions by the deploy, so the two cannot drift.
//
// Values go to the Management API as query parameters, never spliced into the SQL text.

const env = (name) => {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
};

const ref = env('SUPABASE_PROJECT_REF');
const cronSecret = env('CRON_SECRET');
if (!/^[A-Za-z0-9_-]{32,}$/.test(cronSecret)) {
  throw new Error('CRON_SECRET must be at least 32 characters of [A-Za-z0-9_-] (e.g. `openssl rand -hex 32`)');
}
const secrets = {
  notify_url: `https://${ref}.supabase.co/functions/v1/send-notifications`,
  cron_secret: cronSecret,
};

const api = `https://api.supabase.com/v1/projects/${ref}/database/query`;
const headers = { Authorization: `Bearer ${env('SUPABASE_ACCESS_TOKEN')}`, 'Content-Type': 'application/json' };
const sql = async (query, parameters = []) => {
  const res = await fetch(api, { method: 'POST', headers, body: JSON.stringify({ query, parameters }) });
  if (!res.ok) throw new Error(`query failed: ${res.status} ${(await res.text()).slice(0, 300)}`);
  return res.json();
};

// One statement per secret: create, update if changed, or leave alone. Returns what happened.
const UPSERT = `
  with cur as (select id, decrypted_secret from vault.decrypted_secrets where name = $1)
  select case
    when not exists (select 1 from cur) then (select 'created' from vault.create_secret($2, $1))
    when (select decrypted_secret from cur) is distinct from $2
      then (select 'updated' from vault.update_secret((select id from cur), $2))
    else 'unchanged' end as result`;

for (const [name, value] of Object.entries(secrets)) {
  const [{ result }] = await sql(UPSERT, [name, value]);
  console.log(`vault ${name}: ${result}`);
}

const [check] = await sql(
  `select (select decrypted_secret from vault.decrypted_secrets where name = 'notify_url') = $1 as url_ok,
          (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret') = $2 as secret_ok`,
  [secrets.notify_url, secrets.cron_secret]);
if (!check.url_ok || !check.secret_ok) {
  console.error(`Vault verification failed: notify_url ${check.url_ok ? 'ok' : 'WRONG'}, cron_secret ${check.secret_ok ? 'ok' : 'WRONG'}`);
  process.exit(1);
}
console.log(`Vault verified for ${ref}: notify_url and cron_secret match.`);
