-- 001: extensions, private schema, enums (A-02, spec §6.1)

create extension if not exists pgcrypto  with schema extensions;
create extension if not exists pg_trgm   with schema extensions;
create extension if not exists pg_cron;
create extension if not exists pg_net;

create schema if not exists private;      -- NOT exposed through the API

create type public.user_role      as enum ('user', 'admin', 'dev');
create type public.account_status as enum ('active', 'suspended');
create type public.order_status   as enum ('submitted', 'approved', 'rejected', 'cancelled', 'expired');
create type public.ticket_status  as enum ('pending', 'valid', 'used', 'void');
create type public.scan_result    as enum ('ok', 'waiting_approval', 'already_used', 'void', 'invalid');
create type public.notif_status   as enum ('queued', 'sending', 'sent', 'failed', 'dead');
