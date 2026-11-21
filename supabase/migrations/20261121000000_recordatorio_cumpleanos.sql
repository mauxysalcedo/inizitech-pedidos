-- Recordatorio diario de cumpleaños por Telegram.
-- Cada día a las 7:00 a. m. (hora de Colombia, 12:00 UTC) la base llama a la función cumpleanos-diario.
-- La tabla recordatorios_enviados evita enviar dos veces el mismo día.

create table if not exists public.recordatorios_enviados (
  tipo text not null,
  fecha date not null,
  creado_en timestamptz not null default now(),
  primary key (tipo, fecha)
);

-- Tabla interna: RLS activo y sin permisos para el público.
alter table public.recordatorios_enviados enable row level security;
revoke all on public.recordatorios_enviados from anon, authenticated;

select cron.schedule(
  'recordatorio-cumpleanos',
  '0 12 * * *',
  $$
  select net.http_post(
    url := 'https://wzodisidcsvbsbdyzkty.supabase.co/functions/v1/cumpleanos-diario',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb
  )
  $$
);
