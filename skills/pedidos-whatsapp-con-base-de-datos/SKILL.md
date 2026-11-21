---
name: pedidos-whatsapp-con-base-de-datos
description: Implementar un sistema de pedidos para una tienda pequeña con página de pedidos, base de datos en Supabase, publicación en Netlify desde GitHub, alertas y botones por Telegram, garantías, integración con Shopify y respuestas en WhatsApp Business. Usar cuando un negocio copia pedidos a mano desde WhatsApp, cobra por varias formas de pago, quiere precios y domicilios desde una sola fuente, o pide un sistema de pedidos sin servidor propio.
---

# Sistema de pedidos con base de datos, alertas y garantías

## Cuándo usar esta skill
- El negocio recibe pedidos por WhatsApp, Instagram, TikTok o una tienda Shopify y los copia a mano.
- Los precios y domicilios cambian y hay que actualizarlos en varios lugares.
- Se quiere saber cuánto se vende, con qué margen y qué clientes faltan por comprar.
- Se quiere confirmar pagos y llevar garantías sin servidor propio.

No usar cuando el negocio necesita facturación electrónica, inventario real o integración con un ERP. Eso requiere otro diseño.

## Piezas del sistema
| Pieza | Herramienta | Función |
|---|---|---|
| Página de pedidos | HTML, CSS y JavaScript sin frameworks | Lo que ve el cliente. No guarda precios. |
| Base de datos | Supabase (Postgres) | Productos, clientes, pedidos, domicilios, códigos, garantías. Fuente única de verdad. |
| Lógica de pedido | Función SQL `crear_pedido` | Valida, calcula precios y domicilio en la base, guarda todo en una transacción. |
| Publicación de la página | GitHub + Netlify | El código va a GitHub. Cada `push` a la rama principal publica la página. |
| Funciones | Edge Functions de Supabase (Deno) | Alerta de pedidos, botones de Telegram, webhook de Shopify. |
| Alertas y confirmación | Bot de Telegram | Avisa cada pedido con botón 💰 Pagado y 📦 Entregado. Garantías con 🛡️ y ✅. |
| Tienda en línea (opcional) | Shopify + webhooks | Los pedidos y pagos de Shopify entran a la misma base. |
| Respuestas | WhatsApp Business (app) | Bienvenida, ausencia y respuestas rápidas. Sin API oficial. |
| Reportes | Vistas SQL, Power BI | Ventas, costo, margen, clientes sin compra. |

## Método, en orden
1. **Entender el negocio.** Productos, precios, formas de pago, zonas de domicilio, garantía, horarios, dirección que se publica (y cuál no). Escribir las reglas antes de tocar código.
2. **Modelar la base.** Tablas: productos (con `costo` privado y `opciones` en JSON), clientes, pedidos, detalle de pedido (copiar nombre y precio al momento de la venta), domicilios por zona, códigos de descuento, intentos de envío (anti-spam), garantías, contactos de Telegram.
3. **Crear la función de pedido.** Toda la lógica de precios, domicilio, validación y descuento va en la base. El navegador nunca decide un precio.
4. **Seguridad desde el inicio.** Ver la lista de seguridad abajo.
5. **Construir la página.** Lee productos y zonas de la base. Muestra opciones obligatorias (color, modelo). Al enviar, llama a la función; si la base no responde en unos segundos, abre WhatsApp igual con el pedido en texto.
6. **Alertas y botones.** Un disparador en `pedidos` llama a la función de alerta. Otra función recibe los botones de Telegram. Confirmar pago = ya pagó, no "ya entregó". Entregar es un botón aparte.
7. **Garantías.** Comandos `/garantias` y `/garantia INZ-xxxx`. Plazo configurable (ejemplo: 12 días). Cada garantía tiene su botón ✅ Resuelta.
8. **Integrar Shopify (si aplica).** Webhooks `orders/create` y `orders/paid` a una función. Validar el token de la URL y el dominio de la tienda. Responder 200 aunque falle el guardado, para que Shopify no reintente sin fin, y dejar el error en los registros.
9. **Probar sin ensuciar la base real.** Ver la sección de pruebas.
10. **Publicar una sola vez por tanda de cambios.** Cada `push` a la rama principal publica la página en Netlify.
11. **Entregar al dueño.** Explicar cómo ver tablas, cambiar precios, confirmar pedidos, registrar garantías y exportar CSV.

## Lista de seguridad (obligatoria)
- Activar RLS en todas las tablas. Sin políticas, el público no lee ni escribe.
- Quitar al rol público (`anon`) todos los permisos por defecto.
- Permitir al público solo: leer una vista de productos **sin columna de costo**, leer zonas activas, y ejecutar la función de pedido.
- Vistas: no usar `security definer` para lecturas públicas. Usar `security_invoker = true` y dar permisos de columna explícitos.
- Funciones con `security definer`: fijar `search_path`, validar todo dentro, y quitar `execute` a `anon` y `authenticated` si solo las usa el sistema (disparadores, webhooks). El asesor de Supabase lo marca.
- **Ninguna clave dentro del código ni en el repositorio.** Esto incluye tokens de bots, claves de webhooks y tokens de URL. Van en los secretos de Supabase (Edge Functions → Secrets).
- La clave pública va en la página; la clave de servicio solo en funciones del servidor.
- Campo trampa y límite de envíos por celular para frenar spam.
- Autorización de datos: casilla obligatoria, fecha y hora guardadas.

## Despliegue de funciones (no es automático desde GitHub)
- El código de las funciones se guarda en el repositorio como respaldo (`supabase/functions/<nombre>/index.ts` y un README), pero **Supabase no se actualiza solo**. Cada cambio hay que desplegarlo.
- Orden seguro al cambiar una clave:
  1. Crear o cambiar el secreto en Supabase.
  2. Desplegar la función nueva (que lee el secreto del entorno).
  3. Si es un webhook de Telegram, registrarlo de nuevo.
  4. Si es un webhook de Shopify, cambiar la URL en Shopify (la clave va en el parámetro `token`).
  5. Probar con un pedido de prueba y borrarlo al terminar.
- Si el panel de secretos no deja guardar (el asistente puede estar en pausa), se agrega a mano en **Edge Functions → Secrets**. No es un fallo del sistema.
- Desplegar **antes** de cambiar la clave en el servicio externo, o el sistema deja de recibir avisos durante el cambio.

## Pruebas sin ensuciar la base real
- No probar contra la base de producción sin aislar la escritura. Interceptar en el navegador todas las llamadas que no sean GET, con una sola regla para todo el tráfico, para que nunca lleguen a la base.
- Probar la base en una instancia local de Postgres con los mismos roles (`anon`, `authenticated`, `service_role`) y el mismo SQL.
- Pruebas mínimas: pedido válido con total correcto, cada error de validación, límite de envíos, campo trampa, cliente repetido sin perder datos, permisos del público, cancelación a las 48 horas, garantía registrada y resuelta.
- Si se hace un pedido real de prueba, anotar el número y borrar pedido, detalle, cliente, intentos y garantías juntos al terminar.
- Verificar que una llamada sin clave responda 401: confirma que la protección está activa.

## Errores que nos pasaron (y cómo evitarlos)
- **Un intercept de Playwright mal ordenado dejó escribir en producción.** Usar una sola regla para todo el tráfico, no varias.
- **Telegram responde 403 "bot can't send messages to the bot":** el `chat_id` era el del propio bot. Usar el id del usuario humano (chat privado con el bot).
- **Telegram rechaza el webhook con "HTTPS URL must be provided":** la función no debe tomar su URL de la petición interna. Escribir la URL pública fija.
- **Una clave quedó escrita en el código de la función.** Se rota, se mueve a secretos y se redespliega. Revisar también el código que ya está en la nube, no solo el del repositorio.
- **Vista pública marcada como error por el asesor de seguridad:** cambiarla a `security_invoker` y dar permisos por columna.
- **Netlify omitió un despliegue por falta de créditos:** un proyecto dentro de una cuenta gratuita compartida puede quedar pausado. Revisar créditos antes de entregar.
- **Formularios de Netlify sin detectar:** se activa la detección y hay que volver a desplegar una vez para que la detecte.
- **Demasiados despliegues:** juntar cambios y publicar una sola vez.
- **Un pedido de prueba quedó como real.** Probar siempre contra la base aislada, y nunca dejar pedidos de prueba en producción.
- **Un cambio de clave en Shopify deja pedidos sin entrar** hasta que se actualiza la URL. Hacer el cambio de una vez, con el dueño presente.

## Qué entregar al dueño
- Enlace de la página y del panel de la base (solo lectura para él).
- Cómo cambiar un precio en la tabla de productos.
- Cómo confirmar un pedido (botón de Telegram) y que confirmar significa que ya pagó.
- Cómo registrar y cerrar una garantía (`/garantia` y ✅ Resuelta).
- Cómo exportar a CSV para Power BI.
- Qué revisar cada semana: pedidos pendientes, costos sin llenar, garantías abiertas, créditos del hosting.

## Lo que el dueño debe decidir o aportar
- Productos, precios y costos. Sin costos, el margen sale mal.
- Zonas de domicilio y montos.
- Formas de pago y llaves de cuenta.
- Política de garantía y de privacidad. Revisar la de privacidad con un abogado.
- Quién tiene acceso a las cuentas (base, hosting, bot, tienda).
- Qué dirección se publica (en retiro en tienda, no publicar la dirección de la casa).
