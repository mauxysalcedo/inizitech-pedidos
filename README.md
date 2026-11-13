# Inizi Tech · Pedidos rápidos

Página para que los clientes de Inizi Tech elijan productos, ajusten cantidades y envíen su pedido por WhatsApp en pocos toques. Sin registro.

- Un solo archivo: `index.html` (HTML, CSS y JavaScript, sin frameworks).
- Se abre directo en el navegador o se publica tal cual en Netlify o GitHub Pages.

## Configuración

En `index.html`, sección `CONFIG`:

- `whatsapp`: número que recibe los pedidos, en formato internacional sin `+` (ej. `573001234567`).
- `moneda` / `idioma`: por defecto `COP` / `es-CO`.

Los productos están en la lista `PRODUCTOS` (nombre, descripción opcional, precio, categoría y `top: true` para marcar el "Más pedido").
