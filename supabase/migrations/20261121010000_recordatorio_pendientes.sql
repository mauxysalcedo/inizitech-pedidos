-- Recordatorio diario por Telegram de los pedidos que siguen pendientes de pago.
-- Cada día a las 7:05 a. m. (hora de Colombia, 12:05 UTC) la base llama a la función recordatorio-pendientes.
-- Usa la tabla recordatorios_enviados (creada en la migración del recordatorio de cumpleaños) para no repetir el envío del día.

select cron.schedule(
  'recordatorio-pendientes',
  '5 12 * * *',
  $$
  select net.http_post(
    url := 'https://wzodisidcsvbsbdyzkty.supabase.co/functions/v1/recordatorio-pendientes',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb
  )
  $$
);
