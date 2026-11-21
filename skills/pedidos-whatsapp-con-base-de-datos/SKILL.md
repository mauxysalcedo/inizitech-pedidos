---
name: pedidos-whatsapp-con-base-de-datos
description: Método para montar un sistema de pedidos para una tienda pequeña que hoy copia pedidos a mano desde WhatsApp, Instagram o Shopify. Incluye página de pedidos, base de datos en Supabase como fuente única, alertas y confirmación de pago por Telegram, garantías, y respuestas en WhatsApp Business, sin servidor propio. Usar cuando el negocio pierde tiempo copiando pedidos, tiene precios o domicilios en varios lugares, o no sabe cuánto vende ni qué clientes faltan por comprar.
---

# Sistema de pedidos con base de datos, alertas y garantías

## 1. El problema que resuelve

Muchas tiendas pequeñas venden por WhatsApp, Instagram o TikTok, y el pedido pasa por las manos de la dueña varias veces:

- Le escriben el pedido en un chat. Ella lo copia a una hoja, a una nota o a la memoria.
- El precio y el domicilio cambian, y hay que acordarse de actualizarlos en cada lugar (chat, catálogo, hoja, publicación).
- No hay forma rápida de saber qué pedidos están pagados, cuáles faltan por pagar y cuáles ya se entregaron.
- Las garantías se pierden: nadie sabe qué producto se cambió, cuándo, ni si ya venció el plazo.
- Con el tiempo no se sabe cuánto se vende, qué margen queda, ni qué clientes dejaron de comprar.

Lo que hace falta es **un solo lugar donde viven los productos, los precios, los pedidos y las garantías**, y que todo lo demás (la página, las alertas, los reportes) lea de ahí.

## 2. Qué es la solución

Es un sistema pequeño, sin servidor propio, con estas piezas:

| Pieza | Herramienta | Qué hace |
|---|---|---|
| Página de pedidos | HTML, CSS y JavaScript en un solo archivo | Lo que ve el cliente: catálogo, opciones, domicilio, forma de pago. No guarda precios. |
| Base de datos | Supabase (Postgres) | Productos, costos, clientes, pedidos, domicilios, garantías. Es la fuente única de verdad. |
| Lógica del pedido | Función SQL `crear_pedido` | Valida todo, calcula precio y domicilio, y guarda el pedido con su número (INZ-1000, INZ-1001…). |
| Publicación | GitHub + Netlify | El código de la página vive en GitHub. Cada cambio aprobado se publica solo. |
| Funciones | Edge Functions de Supabase | Pequeños programas que avisan pedidos, reciben botones de Telegram y reciben pedidos de Shopify. |
| Alertas y confirmación | Bot de Telegram | Avisa cada pedido con un botón 💰 Pagado. Al entregar, 📦 Entregado. Las garantías tienen 🛡️ y ✅ Resuelta. |
| Tienda en línea (opcional) | Shopify con webhooks | Los pedidos y pagos de Shopify entran a la misma base que los de la página. |
| Respuestas | WhatsApp Business (app) | Bienvenida, ausencia y respuestas rápidas. No usa API oficial. |
| Reportes | Vistas SQL y Power BI | Ventas, costo, margen y clientes sin compra. |

### Cómo fluye un pedido

```
Cliente → Página (Netlify)
            → crear_pedido (Supabase: valida, calcula, guarda, da número INZ)
                → disparador en la tabla pedidos
                    → función de alerta → Telegram (mensaje con botón 💰 Pagado)
                        → dueña toca Pagado
                            → función de botones → pedido confirmado + aviso a todos
                                → dueña toca Entregado → pedido cerrado
Shopify → función de Shopify → mismas tablas (pagado o pendiente)
Garantía → /garantia INZ-xxxx en Telegram → registro → ✅ Resuelta
```

## 3. Principios del método

1. **Una sola fuente de verdad.** Los precios y domicilios viven solo en la base. La página y el bot los leen. Nunca se escriben en dos lugares.
2. **El navegador no decide precios.** Toda la validación y el cálculo ocurren en la base, dentro de la función del pedido. Así nadie puede alterar un precio desde la página.
3. **Lo que es privado no se publica.** El costo de cada producto no sale a ningún cliente. La dirección de la casa de la dueña no aparece nunca en la página.
4. **Confirmar pago y confirmar entrega son acciones distintas.** "Pagado" significa que ya pagó. "Entregado" significa que ya se entregó. No se mezclan.
5. **Ninguna clave dentro del código.** Tokens de bots, claves de webhooks y tokens de URL van en los secretos de Supabase, nunca en el repositorio ni en el chat.
6. **Si algo falla, el cliente no se queda sin pedido.** Si la base no responde en unos segundos, la página abre WhatsApp con el pedido escrito en texto.
7. **Cambios pequeños, publicados de una vez.** Cada `push` a la rama principal publica la página. Se juntan los cambios y se publica una vez.

## 4. Cómo se construye, paso a paso

### Paso 1. Entender el negocio (antes de tocar código)
- **Qué se hace:** listar productos, precios, costos, formas de pago, zonas de domicilio, política de garantía, horario, y qué dirección se publica (en retiro en tienda, nunca la de la casa).
- **Por qué:** casi todos los errores vienen de reglas que nadie escribió. Escribirlas primero evita rehacer la base.
- **Entregable:** un documento corto con las reglas, que la dueña confirma.

### Paso 2. Modelar la base de datos
- **Qué se hace:** crear tablas para productos (con `costo` privado y `opciones` en JSON para color o modelo), clientes, pedidos, detalle del pedido, domicilios por zona, códigos de descuento, intentos de envío, garantías y contactos de Telegram.
- **Por qué:** el detalle del pedido copia el nombre y el precio **del momento de la venta**. Si después cambia el precio, los pedidos viejos no cambian.
- **Entregable:** las migraciones SQL guardadas en el repositorio.

### Paso 3. Crear la función de pedido
- **Qué se hace:** una función SQL `crear_pedido` que recibe los datos del cliente y los productos, revisa que todo sea válido, calcula el total y el domicilio, aplica el descuento si hay código, y guarda todo en una sola transacción.
- **Por qué:** si la validación está en la base, la página puede fallar o cambiar sin romper las reglas.
- **Incluye:** límite de envíos por celular (anti-spam), campo trampa oculto (un campo que solo llenan los robots), y casilla de autorización de datos guardada con fecha y hora.

### Paso 4. Construir la página
- **Qué se hace:** una sola página HTML. Lee productos y zonas de la base con la clave pública. Muestra las opciones obligatorias, el total en vivo y la forma de pago. Al enviar, llama a `crear_pedido` y muestra el número INZ.
- **Por qué:** una sola página es rápida, barata de publicar y fácil de cambiar.
- **Detalle importante:** si la base no responde en unos segundos, se abre WhatsApp con el pedido en texto y el cliente no se queda sin comprar.

### Paso 5. Seguridad (antes de conectar nada más)
- **Qué se hace:**
  - RLS activo en todas las tablas. Sin políticas, el público no lee ni escribe.
  - Quitar al rol público todos los permisos por defecto.
  - Permitir al público solo: leer productos **sin costo**, leer zonas activas y ejecutar `crear_pedido`.
  - Vistas públicas con `security_invoker`, nunca `security definer`.
  - Funciones que solo usa el sistema (disparadores, webhooks) sin permiso para `anon` ni `authenticated`.
- **Por qué:** es más fácil cerrar desde el inicio que arreglar después de que la página ya está pública.
- **Cómo se verifica:** el asesor de seguridad de Supabase, y una llamada sin clave debe responder 401.

### Paso 6. Alertas y confirmación por Telegram
- **Qué se hace:** un disparador en la tabla de pedidos llama a una función que manda el resumen del pedido a cada chat registrado, con botón 💰 Pagado. Otra función recibe los botones y cambia el estado.
- **Por qué:** la dueña se entera al instante, sin abrir un panel, y confirma desde el mismo teléfono.
- **Reglas:** solo los chats registrados pueden tocar botones. El chat que se usa es el de la persona, no el del bot (el bot no puede escribirse a sí mismo).

### Paso 7. Garantías
- **Qué se hace:** tabla de garantías ligada al pedido. Comandos `/garantias` (ver abiertas) y `/garantia INZ-xxxx` (registrar). Cada garantía tiene su botón ✅ Resuelta. Se avisa si pasa el plazo (por ejemplo, 12 días).
- **Por qué:** sin registro, las garantías se pierden y no se sabe qué producto falló más.

### Paso 8. Integrar Shopify (si el negocio también vende ahí)
- **Qué se hace:** webhooks de Shopify para `orders/create` y `orders/paid` apuntan a una función. La función revisa el token de la URL y el dominio de la tienda, y guarda el pedido con las mismas funciones de la base.
- **Por qué:** un solo lugar para todos los pedidos, sin copiar a mano desde Shopify.
- **Regla:** la función responde 200 aunque falle el guardado, para que Shopify no reintente sin fin, y deja el error en los registros.

### Paso 9. Publicar y desplegar
- **Qué se hace:**
  - La página: `push` a la rama principal de GitHub. Netlify la publica sola.
  - Las funciones: Supabase **no** las actualiza desde GitHub. Se despliegan a mano (con el asistente o el panel). El código de cada función vive en el repositorio como respaldo.
- **Orden seguro al cambiar una clave:**
  1. Crear o cambiar el secreto en Supabase.
  2. Desplegar la función que lee el secreto del entorno.
  3. Si es Telegram, registrar el webhook de nuevo.
  4. Si es Shopify, cambiar la URL en Shopify.
  5. Probar con un pedido de prueba y borrarlo.
- **Por qué este orden:** si cambias la clave en el servicio antes de desplegar, los avisos dejan de llegar.

### Paso 10. Probar sin ensuciar la base real
- **Qué se hace:** interceptar en el navegador todas las llamadas que no sean de lectura, con una sola regla para todo el tráfico. Probar la base en una instancia local de Postgres con los mismos roles.
- **Pruebas mínimas:** pedido válido con total correcto, cada error de validación, límite de envíos, campo trampa, cliente repetido sin perder datos, permisos del público, cancelación a las 48 horas, garantía registrada y resuelta, llamada sin clave responde 401.
- **Si se hace un pedido real de prueba:** anotar el número y borrar pedido, detalle, cliente, intentos y garantías juntos.

### Paso 11. Entregar y operar
- **Qué se le enseña a la dueña:** dónde ver las tablas, cómo cambiar un precio, cómo confirmar pago y entrega, cómo registrar y cerrar una garantía, cómo exportar CSV para Power BI.
- **Qué revisar cada semana:** pedidos pendientes, costos sin llenar, garantías abiertas, créditos del hosting.

## 5. Errores que nos pasaron (y la lección)

- **Un intercept de Playwright mal ordenado dejó escribir en producción.** Lección: una sola regla para todo el tráfico de pruebas.
- **Telegram respondió 403 "bot can't send messages to the bot".** Lección: el `chat_id` debe ser el de la persona, no el del bot.
- **Telegram rechazó el webhook con "HTTPS URL must be provided".** Lección: la URL pública va escrita fija en el código.
- **Una clave quedó escrita dentro de la función desplegada.** Lección: revisar también el código que ya está en la nube, no solo el del repositorio, y mover toda clave a secretos.
- **Vista pública marcada como error por el asesor de seguridad.** Lección: `security_invoker` y permisos por columna.
- **Netlify omitió un despliegue por falta de créditos.** Lección: revisar créditos antes de entregar.
- **Pedidos de prueba quedaron como reales.** Lección: probar contra base aislada, y borrar lo que se crea.
- **Un cambio de clave en Shopify dejó pedidos sin entrar hasta actualizar la URL.** Lección: cambiar la clave y la URL en el mismo momento, con el dueño presente.

## 6. Lo que el dueño decide o aporta

- Productos, precios y costos. Sin costos, el margen sale mal.
- Zonas de domicilio y montos.
- Formas de pago y llaves de cuenta.
- Política de garantía y de privacidad (la de privacidad, revisada por un abogado).
- Qué dirección se publica.
- Quién tiene acceso a la base, al hosting, al bot y a la tienda.
