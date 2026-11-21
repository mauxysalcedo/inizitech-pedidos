import { createClient } from 'npm:@supabase/supabase-js@2';

// Manda la alerta de cada pedido nuevo a los contactos registrados en Telegram.
// Secretos usados: TELEGRAM_BOT_TOKEN (y TELEGRAM_CHAT_ID solo como respaldo).
const dinero = (n) => '$ ' + Math.round(n).toLocaleString('es-CO');
const db = () => createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
const NOMBRE_PAGO = { contado: 'Efectivo', transferencia: 'Transferencia', sistecredito: 'Sistecrédito', bold: 'Bold (pago en línea)' };

const chatsRegistrados = async () => {
  const { data } = await db().from('telegram_contactos').select('chat_id');
  if (data && data.length > 0) return data.map(c => String(c.chat_id));
  const legado = Deno.env.get('TELEGRAM_CHAT_ID');
  return legado ? [legado] : [];
};

Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => ({}));
    const id = body?.id ?? body?.record?.id;
    if (!id) return new Response('sin id', { status: 400 });
    const token = Deno.env.get('TELEGRAM_BOT_TOKEN');
    if (!token) return new Response('falta TELEGRAM_BOT_TOKEN', { status: 500 });
    const chats = await chatsRegistrados();
    if (chats.length === 0) return new Response('sin contactos registrados', { status: 200 });

    const consultar = () => db().from('pedidos')
      .select('numero,total,subtotal,descuento,costo_envio,entrega,municipio_entrega,direccion_entrega,forma_pago,cuotas,notas,canal,estado,estado_pago,clientes(nombre,celular,email),detalle_pedido(cantidad,nombre_producto,especificaciones,precio_unitario)')
      .eq('id', id).single();
    let { data: p, error } = await consultar();
    if (!error && p && (!p.detalle_pedido || p.detalle_pedido.length === 0)) {
      await new Promise(r => setTimeout(r, 2000));
      ({ data: p, error } = await consultar());
    }
    if (error || !p) return new Response('pedido no encontrado: ' + (error?.message ?? ''), { status: 404 });

    const cliente = Array.isArray(p.clientes) ? p.clientes[0] : p.clientes;
    const lineas = (p.detalle_pedido || []).map(d => {
      const esp = Object.values(d.especificaciones || {}).filter(Boolean).join(', ');
      return '- ' + d.cantidad + 'x ' + d.nombre_producto + (esp ? ' (' + esp + ')' : '') + ' - ' + dinero(d.precio_unitario * d.cantidad);
    }).join('\n');
    const entrega = p.entrega === 'domicilio'
      ? ('Domicilio: ' + (p.municipio_entrega ?? '') + ' - ' + (p.direccion_entrega ?? ''))
      : 'Pasa a recoger';
    const pago = p.forma_pago === 'sistecredito'
      ? ('Sistecrédito (' + (p.cuotas ?? '?') + ' cuotas)')
      : (NOMBRE_PAGO[p.forma_pago] ?? p.forma_pago);
    const yaPagado = p.estado_pago === 'pagado';
    const origen = p.canal === 'shopify' ? 'Tienda Shopify' : 'Página de pedidos';

    const partes = [
      'Nuevo pedido ' + p.numero + ' · ' + origen,
      '',
      (cliente?.nombre ?? 'Cliente') + ' - ' + (cliente?.celular ?? ''),
      cliente?.email ? cliente.email : null,
      '',
      lineas,
      '',
      'Subtotal: ' + dinero(p.subtotal),
      p.descuento ? ('Descuento: -' + dinero(p.descuento)) : null,
      p.costo_envio ? ('Envío: ' + dinero(p.costo_envio)) : null,
      'Total: ' + dinero(p.total),
      '',
      entrega,
      'Pago: ' + pago,
      yaPagado ? '✅ YA PAGADO' : '⏳ Pendiente de pago',
      p.notas ? ('Notas: ' + p.notas) : null,
    ];
    const texto = partes.filter(l => l !== null).join('\n');

    const boton = yaPagado
      ? { text: '📦 Entregado', callback_data: 'entregado:' + p.numero }
      : { text: '💰 Pagado', callback_data: 'pagado:' + p.numero };

    let huboError = false;
    for (const chat_id of chats) {
      const r = await fetch('https://api.telegram.org/bot' + token + '/sendMessage', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id, text: texto, reply_markup: { inline_keyboard: [[boton]] } }),
      });
      if (!r.ok) huboError = true;
    }
    return new Response(huboError ? 'enviado con errores' : 'enviado', { status: huboError ? 502 : 200 });
  } catch (e) {
    return new Response('error: ' + e.message, { status: 500 });
  }
});
