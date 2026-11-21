---
name: pedidos-whatsapp-con-base-de-datos
description: Método completo para montar un sistema de pedidos de una tienda pequeña que hoy copia pedidos a mano desde WhatsApp, Instagram o Shopify. Cubre la página de pedidos, la base de datos en Supabase como fuente única, las alertas y confirmaciones por Telegram, el vencimiento automático de pedidos sin pagar, las garantías, la integración con Shopify, las respuestas de WhatsApp Business, el seguimiento de clientes que no compraron y los reportes. Usar cuando el negocio pierde tiempo copiando pedidos, tiene precios en varios lugares, cobra por varias formas de pago, o no sabe qué pedidos están pendientes, qué clientes faltan por comprar o qué garantías siguen abiertas.
---

# Sistema de pedidos: base de datos, alertas, seguimiento y garantías

## 1. El problema que resuelve

Muchas tiendas pequeñas venden por WhatsApp, Instagram o TikTok, y cada pedido pasa por las manos de la dueña varias veces:

- Le escriben el pedido en un chat. Ella lo copia a una hoja, a una nota o a la memoria.
- El precio y el domicilio cambian, y hay que acordarse de actualizarlos en cada lugar (chat, catálogo, hoja, publicación).
- Nadie sabe con certeza qué pedidos están pagados, cuáles siguen esperando pago y cuáles ya se entregaron.
- Los pedidos que el cliente nunca paga se quedan para siempre en la lista, y la dueña no sabe cuándo soltarlos.
- Los clientes que pidieron algo y no volvieron a escribir se pierden, porque nadie les hace seguimiento.
- Las garantías se pierden: no se sabe qué producto se cambió, cuándo, ni si ya venció el plazo.
- Con el tiempo no se sabe cuánto se vende, qué margen queda, ni qué clientes dejaron de comprar.

Lo que hace falta es **un solo lugar donde viven los productos, los precios, los pedidos, los pagos y las garantías**, y que todo lo demás (la página, las alertas, los recordatorios, los reportes) lea y escriba ahí.

## 2. Qué es la solución

Es un sistema pequeño, sin servidor propio, formado por:

- **Una página web** (un solo archivo HTML, publicado en Netlify) donde el cliente elige productos, opciones, forma de pago y entrega.
- **Una base de datos** en Supabase (Postgres) que guarda todo y decide las reglas: precios, domicilios, validaciones, estados de los pedidos.
- **Funciones** en Supabase que reaccionan a eventos: avisar un pedido nuevo, recibir los botones de Telegram, recibir pedidos de Shopify.
- **Tareas programadas** en la base que se ejecutan solas (vencer pedidos sin pago, limpiar registros viejos).
- **Telegram** como el teléfono de la dueña: avisos, botones de pagado y entregado, garantías.
- **WhatsApp Business** (la app, sin API) para respuestas automáticas y rápidas.
- **Vistas de reporte** para ventas, margen, clientes que faltan por comprar y cumpleaños.

## 3. Mapa completo: qué hace cada pieza

### 3.1 Página de pedidos
- Carga el catálogo y las zonas de domicilio desde la base con la clave pública. No guarda precios.
- Muestra productos por categoría, pestaña "Lo más pedido", búsqueda, opciones obligatorias (color, modelo) y total en vivo.
- Pide datos del cliente (nombre, celular, correo obligatorio, aceptación de datos). Si es domicilio, pide municipio y dirección; si es retiro, no pide dirección y no se publica la dirección de la tienda.
- Forma de pago: efectivo, transferencia, Sistecrédito (con cuotas) y, cuando se decida, un enlace de pago en línea.
- Al enviar, llama a la función `crear_pedido`. Si la base responde, muestra el número del pedido (INZ-1000, INZ-1001…).
- Si la base no responde en unos segundos, abre WhatsApp con el pedido escrito en texto, para que el cliente no se quede sin comprar.
- Respaldo: copia el pedido a un formulario oculto de Netlify para tener un registro aunque falle la base.

### 3.2 Función `crear_pedido` (en la base)
- Valida todos los campos y las reglas de negocio.
- Calcula precios desde la tabla de productos (nunca desde el navegador).
- Calcula el domicilio según el municipio. Si el municipio es "Otro", el domicilio queda en 0 y se confirma por WhatsApp.
- Aplica códigos de descuento si existen.
- Límite anti-spam: máximo 3 pedidos por celular cada 10 minutos. Campo trampa: si un robot lo llena, el pedido se descarta.
- Guarda cliente, pedido y detalle en una sola transacción, con el número INZ.
- Deja el pedido en estado **pendiente**. Ese es el punto de partida de todo lo demás.

### 3.3 Disparador de alerta
- Cada vez que se inserta un pedido, un disparador llama a la función de alerta.

### 3.4 Función de alerta (`alerta-pedido`)
- Lee el pedido completo: cliente, productos con opciones, subtotal, descuento, envío, total, entrega, forma de pago y notas.
- Envía el resumen a cada chat registrado de Telegram, con un botón: **💰 Pagado** si está pendiente, **📦 Entregado** si ya está pagado.

### 3.5 Función de botones (`telegram-webhook`)
Recibe lo que la dueña toca en Telegram. Solo responde a chats registrados.
- **💰 Pagado:** cambia el pedido a confirmado y pagado. Avisa a todos los chats. Confirmar significa que ya pagó, no que ya se entregó.
- **📦 Entregado:** cambia el pedido a entregado, con fecha de entrega. Solo se permite si antes estaba pagado. Avisa a todos.
- **🛡️ Garantía:** pide la falla por respuesta obligatoria y registra la garantía ligada al pedido.
- **✅ Resuelta:** cierra la garantía.
- **/garantias:** lista las garantías abiertas, con días transcurridos y alerta si pasan el plazo (12 días).
- **/garantia INZ-xxxx:** inicia el registro de una garantía de ese pedido.
- Cualquier otro mensaje devuelve la lista de comandos.

### 3.6 Tareas programadas en la base
- **Vencer pedidos sin pago:** cada 15 minutos, todo pedido que sigue **pendiente** después de **48 horas** pasa a **cancelado**, con el motivo "Vencido: sin confirmar en 48 horas".
- **Limpiar intentos de envío:** cada día a las 8:00, se borran los registros de intentos de más de un día. Sirven solo para el límite anti-spam.

### 3.7 Función de Shopify (`shopify-pedidos`)
- Recibe los webhooks `orders/create` y `orders/paid` de la tienda Shopify.
- Revisa el token de la URL y el dominio de la tienda. Sin token válido responde 401.
- `orders/create` registra el pedido. `orders/paid` marca el pedido como pagado y, si no existía, lo registra ya pagado.
- Si algo falla al guardar, responde 200 para que Shopify no reintente sin fin, y deja el error en los registros.

### 3.8 Vistas de reporte (en la base)
- **productos_publicos:** lo que ve el público. No incluye el costo.
- **resumen_ventas:** ventas, costo y margen por periodo, para Power BI.
- **oportunidades_seguimiento:** clientes con autorización de datos que no tienen ningún pedido confirmado o entregado, y que están en uno de estos casos:
  - No tienen ningún pedido (registrados sin compra).
  - Su último pedido fue cancelado.
  - Su último pedido sigue pendiente desde hace más de 2 horas (pedido abandonado).
  Incluye el último producto que miraron o pidieron, para hacer seguimiento.
- **cumpleanos_del_mes:** clientes que cumplen años este mes, para un mensaje de felicitación (el envío automático aún no está hecho).

### 3.9 WhatsApp Business (app, sin API)
- **Mensaje de bienvenida** y **mensaje de ausencia:** responden solos cuando la dueña no contesta. Dicen el horario y que el pedido se hace por la página.
- **Respuestas rápidas** (atajos con /): precios, formas de pago, domicilio, garantía, y el enlace de la página. Se escriben una vez y se usan muchas veces, para no repetir el mismo texto.
- No usa API oficial de Meta. La verificación de negocio de Meta no se tramita porque la API es de pago.

## 4. Ciclo de vida de un pedido

| Estado | Quién lo pone | Cómo sale de ahí |
|---|---|---|
| **pendiente** (sin pagar) | El cliente, al enviar la página o al llegar por Shopify | Pagado → confirmado. O pasan 48 horas → cancelado automático |
| **confirmado** (pagado) | La dueña, con 💰 Pagado en Telegram (o Shopify con `orders/paid`) | Entregado → entregado |
| **entregado** | La dueña, con 📦 Entregado en Telegram | Fin. Desde aquí se pueden registrar garantías |
| **cancelado** | El sistema (48 horas sin pago) o la dueña manualmente | Fin |

`estado_pago` puede ser **pendiente** o **pagado**, y se usa para los botones de Telegram.

## 5. Cuando el cliente o la dueña tardan

Esta es la parte que más se pierde sin un método. Así responde el sistema a cada caso:

### 5.1 El cliente hace el pedido y no paga
- El pedido queda en **pendiente** y la dueña recibe la alerta con 💰 Pagado.
- Si pasan **48 horas** sin pago, el sistema lo cancela solo, cada 15 minutos, con motivo registrado.
- Mientras tanto, el cliente aparece en **oportunidades_seguimiento** como "pedido abandonado" a partir de las 2 horas, con el producto que pidió. Sirve para escribirle y preguntar si aún quiere el pedido.
- **Regla:** no se confirma nada que no esté pagado. Si el cliente dice que ya pagó, la dueña revisa la cuenta antes de tocar 💰 Pagado.

### 5.2 El cliente pide por WhatsApp y no responde
- Si la dueña no contesta, el mensaje de ausencia avisa el horario y redirige a la página de pedidos.
- Si el cliente nunca hizo un pedido en la página, aparece en **oportunidades_seguimiento** como "registrado sin compra" (si está registrado y autorizó datos).
- Los atajos de WhatsApp evitan que la dueña escriba lo mismo cada vez.

### 5.3 El cliente tarda en recoger o en confirmar la entrega
- El pedido sigue en **confirmado** hasta que la dueña toca 📦 Entregado. Mientras esté en confirmado, sigue visible como pendiente de entrega en la base.
- Si es domicilio, la dueña decide cuándo sale; el sistema no calcula tiempos de entrega (se dijo 30 a 50 minutos en la página, y luego se quitó para no prometer tiempos que no se cumplen).

### 5.4 La dueña tarda en confirmar pagos
- **Hoy el sistema no avisa de los pedidos pendientes que llevan mucho tiempo.** El alerta solo llega cuando se crea el pedido, no como recordatorio.
- Lo que sí hace: vence los pedidos a las 48 horas, así que nunca quedan pendientes para siempre.
- **Mejora recomendada:** un recordatorio en Telegram cada cierto tiempo con los pedidos pendientes. Aún no está hecho.

### 5.5 Garantía que tarda en resolverse
- La garantía queda abierta y aparece en `/garantias` con los días transcurridos.
- Pasados 12 días, aparece con alerta ⚠️.
- Se cierra con ✅ Resuelta cuando el producto ya se cambió o reparó.

### 5.6 El cliente paga por Shopify y tarda en llegar el aviso
- Shopify reintenta los avisos que no le confirmaron. Si la URL o el token cambiaron, hay que actualizar la dirección en Shopify para que los reintentos lleguen bien.
- Si un pedido de Shopify no aparece en la base, se revisa en los registros de la función y en Shopify, y se carga a mano si hace falta.

## 6. Garantías

- Se registran desde Telegram, ligadas al número del pedido.
- Cada garantía tiene falla, fecha de apertura, fecha de resolución y estado (abierta o resuelta).
- El plazo de garantía es de 12 días (configurable en el código).
- Sin garantías registradas, la tabla de garantías aparece vacía, y eso es normal al principio.

## 7. Principios del método

1. **Una sola fuente de verdad.** Precios y domicilios viven solo en la base. La página y el bot los leen.
2. **El navegador no decide precios ni estados.** Toda validación y cambio de estado ocurre en la base o en las funciones.
3. **Lo privado no se publica.** El costo no sale a ningún cliente. La dirección de la casa no aparece nunca en la página.
4. **Pagado y entregado son cosas distintas.** Cada botón hace una sola cosa.
5. **Nada se confirma sin pago.** Y nada queda pendiente para siempre: el sistema lo vence a las 48 horas.
6. **Ninguna clave dentro del código.** Tokens y claves van en los secretos de Supabase.
7. **Si algo falla, el cliente no se queda sin comprar.** WhatsApp sirve de respaldo.
8. **Cambios pequeños, publicados de una vez.** Cada `push` a la rama principal publica la página.

## 8. Cómo se construye, paso a paso

### Paso 1. Entender el negocio
- **Qué:** productos, precios, costos, formas de pago, zonas de domicilio, garantía, horario, dirección que se publica.
- **Por qué:** casi todos los errores vienen de reglas que nadie escribió.
- **Entregable:** un documento corto con las reglas, que la dueña confirma.

### Paso 2. Modelar la base
- **Qué:** tablas de productos (con costo privado y opciones en JSON), clientes, pedidos, detalle, domicilios por zona, códigos de descuento, intentos de envío, garantías y contactos de Telegram.
- **Por qué:** el detalle copia nombre y precio del momento de la venta. Si el precio cambia después, los pedidos viejos no cambian.

### Paso 3. Crear `crear_pedido`
- **Qué:** la función que valida, calcula, aplica descuento, aplica anti-spam y guarda todo en una transacción.

### Paso 4. Construir la página
- **Qué:** una sola página HTML que lee de la base y llama a `crear_pedido`.
- **Por qué:** rápida, barata de publicar y fácil de cambiar.

### Paso 5. Seguridad, antes de conectar nada más
- RLS activo en todas las tablas.
- Quitar al público todos los permisos por defecto, y darle solo: leer productos sin costo, leer zonas activas y ejecutar `crear_pedido`.
- Vistas públicas con `security_invoker`, no `security definer`.
- Funciones internas (disparadores, webhooks) sin permiso para `anon` ni `authenticated`.
- **Verificación:** el asesor de seguridad de Supabase, y una llamada sin clave que responda 401.

### Paso 6. Alertas y botones de Telegram
- **Qué:** disparador → función de alerta → mensaje con botón. Función de botones → cambio de estado → aviso a todos.
- **Regla:** solo los chats registrados pueden tocar botones. El chat es el de la persona, no el del bot.

### Paso 7. Vencimiento y tareas programadas
- **Qué:** tarea cada 15 minutos que cancela pedidos pendientes de más de 48 horas. Tarea diaria que limpia intentos viejos.
- **Por qué:** para que la lista de pendientes sea real y no crezca para siempre.

### Paso 8. Garantías
- **Qué:** tabla ligada al pedido, comandos `/garantias` y `/garantia INZ-xxxx`, botones ✅ Resuelta, alerta por plazo.

### Paso 9. Integrar Shopify (si aplica)
- **Qué:** webhooks `orders/create` y `orders/paid` a una función, con token en la URL y revisión del dominio.
- **Regla:** responder 200 aunque falle el guardado, para que Shopify no reintente sin fin.

### Paso 10. Seguimiento y reportes
- **Qué:** vista de oportunidades (registrados sin compra, pedidos abandonados, cancelados), vista de cumpleaños, vista de ventas y margen para Power BI.

### Paso 11. Publicar y desplegar
- **Página:** `push` a la rama principal. Netlify la publica sola.
- **Funciones:** Supabase **no** las actualiza desde GitHub. Se despliegan a mano. El código vive en el repositorio como respaldo.
- **Orden seguro al cambiar una clave:**
  1. Crear o cambiar el secreto en Supabase.
  2. Desplegar la función que lee el secreto del entorno.
  3. Si es Telegram, registrar el webhook de nuevo.
  4. Si es Shopify, cambiar la URL en Shopify.
  5. Probar con un pedido de prueba y borrarlo.
- Si cambias la clave en el servicio antes de desplegar, los avisos dejan de llegar.

### Paso 12. Probar sin ensuciar la base real
- Interceptar en el navegador todas las llamadas que no sean de lectura, con una sola regla.
- Probar la base en una instancia local de Postgres con los mismos roles.
- Pruebas mínimas: pedido válido, cada error de validación, límite de envíos, campo trampa, cliente repetido, permisos del público, vencimiento a las 48 horas, garantía registrada y resuelta, llamada sin clave responde 401.
- Si se hace un pedido real de prueba, anotar el número y borrar pedido, detalle, cliente, intentos y garantías juntos.

### Paso 13. Entregar y operar
- **A la dueña se le enseña:** dónde ver las tablas, cómo cambiar un precio, cómo confirmar pago y entrega, cómo registrar y cerrar garantías, qué significan los estados, cómo exportar CSV.
- **Cada semana:** revisar pedidos pendientes, costos sin llenar, garantías abiertas, oportunidades de seguimiento, créditos del hosting.

## 9. Errores que nos pasaron (y la lección)

- **Un intercept de Playwright mal ordenado dejó escribir en producción.** Una sola regla para todo el tráfico de pruebas.
- **Telegram respondió 403 "bot can't send messages to the bot".** El `chat_id` debe ser el de la persona.
- **Telegram rechazó el webhook con "HTTPS URL must be provided".** La URL pública va fija en el código.
- **Una clave quedó escrita dentro de la función desplegada.** Revisar también el código que está en la nube, y mover toda clave a secretos.
- **Vista pública marcada como error por el asesor de seguridad.** `security_invoker` y permisos por columna.
- **Netlify omitió un despliegue por falta de créditos.** Revisar créditos antes de entregar.
- **Pedidos de prueba quedaron como reales.** Probar contra base aislada, y borrar lo que se crea.
- **El panel de secretos de Supabase se pausó y no guardó nada.** Se agregan a mano en Edge Functions → Secrets.
- **Un cambio de clave en Shopify dejó pedidos sin entrar** hasta actualizar la URL. Cambiar clave y URL en el mismo momento.

## 10. Lo que está hecho y lo que falta

**Hecho:** página, base, crear_pedido, alertas, botones de pagado y entregado, garantías, vencimiento a 48 horas, integración con Shopify, vistas de seguimiento, cumpleaños y ventas, respuestas de WhatsApp.

**Falta o está pendiente:**
- Recordatorio en Telegram de pedidos pendientes que llevan mucho tiempo.
- Mensaje automático de cumpleaños (correo con Resend).
- Enlace de pago en línea (Bold), aún sin decidir.
- Llave de transferencia del negocio por confirmar.
- Costos de los productos, que la dueña aún no ha cargado.
- Exportación de Google Forms a CSV.
- Página de catálogo para compartir.
- Agente de ventas para responder preguntas.

## 11. Lo que el dueño decide o aporta
- Productos, precios y costos. Sin costos, el margen sale mal.
- Zonas de domicilio y montos.
- Formas de pago y llaves de cuenta.
- Política de garantía y de privacidad (la de privacidad, revisada por un abogado).
- Qué dirección se publica.
- Quién tiene acceso a la base, al hosting, al bot, a WhatsApp y a la tienda.
