# Funciones de Supabase de Inizitech

Estas son las Edge Functions que están desplegadas en el proyecto de Supabase `wzodisidcsvbsbdyzkty`.
El código de este repositorio es la copia de respaldo. **Supabase no se actualiza solo desde GitHub**: cada cambio hay que desplegarlo a mano (con el asistente o en el panel de Supabase).

## Funciones

| Carpeta | Para qué sirve | Quién la llama |
|---|---|---|
| `alerta-pedido/` | Manda a Telegram el aviso de cada pedido nuevo, con el botón 💰 Pagado o 📦 Entregado | Disparador `trg_alerta_pedido` en la tabla `pedidos` |
| `telegram-webhook/` | Recibe los botones de Telegram y los comandos `/garantias` y `/garantia INZ-xxxx` | Telegram |
| `shopify-pedidos/` | Recibe los pedidos y pagos de la tienda Shopify | Shopify (webhooks `orders/create` y `orders/paid`) |
| `cumpleanos-diario/` | Avisa por Telegram quién cumple años hoy, con un botón que abre WhatsApp con el saludo escrito | Tarea programada `recordatorio-cumpleanos` en la base, todos los días a las 7:00 a. m. (hora de Colombia) |

`cumpleanos-diario` solo actúa entre las 7:00 y las 9:59 a. m. de Colombia, solo envía una vez por día (tabla `recordatorios_enviados`) y no devuelve datos de clientes. Solo usa clientes que autorizaron el tratamiento de datos. Su migración está en `supabase/migrations/20261121000000_recordatorio_cumpleanos.sql`.

## Secretos (nunca en el código)

Se configuran en Supabase: **Project Settings → Edge Functions → Secrets** (o con la herramienta de secretos).

| Secreto | Usado por | Qué es |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | las tres | Token del bot de Telegram (BotFather) |
| `TELEGRAM_WEBHOOK_SECRET` | `telegram-webhook` | Clave que Telegram envía en cada aviso. Se registra con `telegram-webhook?configurar=1` |
| `SHOPIFY_CLAVE` | `shopify-pedidos` | Parte del enlace que Shopify llama (`?token=...`). Hay que cambiarla también en Shopify |
| `TELEGRAM_CHAT_ID` | `alerta-pedido` | Solo respaldo, si la tabla `telegram_contactos` está vacía |

`SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` los pone Supabase automáticamente.

## Cómo desplegar

1. Configurar o cambiar los secretos.
2. Desplegar la función con el código de su carpeta (`index.ts`), con `verify_jwt = false`.
3. Si cambió el secreto de Telegram, abrir una vez `https://wzodisidcsvbsbdyzkty.supabase.co/functions/v1/telegram-webhook?configurar=1`. Debe responder `"configurado": true`.
4. Si cambió `SHOPIFY_CLAVE`, actualizar en Shopify (Configuración → Notificaciones → Webhooks) la dirección con `?token=` nuevo.
5. Probar con un pedido de prueba y borrarlo al terminar.

## Reglas
- Cualquier clave nueva va como secreto, no como texto dentro de `index.ts`.
- Si una clave se filtra, se cambia en el secreto, se redespliega y se actualiza en el servicio que la usa (Telegram o Shopify).
