import { createClient } from 'npm:@supabase/supabase-js@2';

// Ninguna clave va en el código. Están en los secretos de Supabase:
//   TELEGRAM_BOT_TOKEN       -> token del bot (BotFather)
//   TELEGRAM_WEBHOOK_SECRET  -> clave que Telegram envía en cada aviso
const WEBHOOK_URL = 'https://wzodisidcsvbsbdyzkty.supabase.co/functions/v1/telegram-webhook';
const SECRETO = Deno.env.get('TELEGRAM_WEBHOOK_SECRET') ?? '';
const DIAS_GARANTIA = 12;

const TOKEN = () => Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const API = (metodo, datos) => fetch(`https://api.telegram.org/bot${TOKEN()}/${metodo}`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(datos),
}).then(r => r.json());
const db = () => createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));

const chatsRegistrados = async () => {
  const { data } = await db().from('telegram_contactos').select('chat_id');
  return (data || []).map(c => String(c.chat_id));
};
const esRegistrado = async (chatId) => (await chatsRegistrados()).includes(String(chatId));
const avisarATodos = async (texto) => {
  for (const chat_id of await chatsRegistrados()) await API('sendMessage', { chat_id, text: texto });
};
const hoyColombia = () => new Date().toLocaleDateString('en-CA', { timeZone: 'America/Bogota' });
const diasDesde = (fecha) => Math.floor((Date.now() - new Date(fecha).getTime()) / 86400000);

const BOTON_ENTREGADO = (n) => ({ inline_keyboard: [[{ text: '📦 Entregado', callback_data: 'entregado:' + n }]] });
const BOTON_GARANTIA = (n) => ({ inline_keyboard: [[{ text: '🛡️ Garantía', callback_data: 'garantia:' + n }]] });
const BOTON_RESUELTA = (id) => ({ inline_keyboard: [[{ text: '✅ Resuelta', callback_data: 'resuelta:' + id }]] });
const SIN_BOTONES = { inline_keyboard: [] };

const cambiarBotones = (cq, markup) => cq.message
  ? API('editMessageReplyMarkup', { chat_id: cq.message.chat.id, message_id: cq.message.message_id, reply_markup: markup })
  : Promise.resolve();

// ---------- Pagado / Entregado ----------
async function marcarPagado(cq, numero) {
  const { data, error } = await db().from('pedidos')
    .update({ estado: 'confirmado', estado_pago: 'pagado' })
    .eq('numero', numero).eq('estado', 'pendiente').select('numero');
  if (error) return 'No se pudo marcar como pagado. Intenta de nuevo.';
  if (data && data.length > 0) {
    await cambiarBotones(cq, BOTON_ENTREGADO(numero));
    await avisarATodos(numero + ' 💰 pagado. Cuando lo entregues, toca 📦 Entregado.');
    return numero + ' marcado como pagado.';
  }
  const { data: p } = await db().from('pedidos').select('estado,estado_pago').eq('numero', numero).maybeSingle();
  if (!p) return numero + ' no existe.';
  if (p.estado === 'entregado') { await cambiarBotones(cq, BOTON_GARANTIA(numero)); return numero + ' ya estaba entregado.'; }
  if (p.estado === 'cancelado') { await cambiarBotones(cq, SIN_BOTONES); return numero + ' está cancelado.'; }
  await cambiarBotones(cq, BOTON_ENTREGADO(numero));
  return numero + ' ya estaba pagado.';
}

async function marcarEntregado(cq, numero) {
  const { data: p, error } = await db().from('pedidos').select('estado,estado_pago').eq('numero', numero).maybeSingle();
  if (error) return 'No se pudo revisar el pedido. Intenta de nuevo.';
  if (!p) return numero + ' no existe.';
  if (p.estado === 'entregado') { await cambiarBotones(cq, BOTON_GARANTIA(numero)); return numero + ' ya estaba entregado.'; }
  if (p.estado === 'cancelado') { await cambiarBotones(cq, SIN_BOTONES); return numero + ' está cancelado.'; }
  if (p.estado === 'pendiente' && p.estado_pago !== 'pagado') return 'Primero marca 💰 Pagado en ' + numero + '.';
  const { error: e2 } = await db().from('pedidos')
    .update({ estado: 'entregado', estado_pago: 'pagado', fecha_entrega: hoyColombia() })
    .eq('numero', numero).neq('estado', 'entregado');
  if (e2) return 'No se pudo marcar como entregado. Intenta de nuevo.';
  await cambiarBotones(cq, BOTON_GARANTIA(numero));
  await avisarATodos(numero + ' 📦 entregado. ¡Pedido cerrado!');
  return numero + ' marcado como entregado.';
}

// ---------- Garantías ----------
const PREGUNTA = (n) => '🛡️ Garantía ' + n + '\n¿Qué falla tiene el producto? Responde a este mensaje.';

async function pedirFalla(chatId, numero) {
  const { data: p } = await db().from('pedidos').select('id').eq('numero', numero).maybeSingle();
  if (!p) { await API('sendMessage', { chat_id: chatId, text: numero + ' no existe.' }); return numero + ' no existe.'; }
  await API('sendMessage', {
    chat_id: chatId, text: PREGUNTA(numero),
    reply_markup: { force_reply: true, input_field_placeholder: 'Ej: no carga el estuche' },
  });
  return 'Escribe la falla de ' + numero;
}

async function registrarGarantia(chatId, numero, falla) {
  const { data: p } = await db().from('pedidos').select('id').eq('numero', numero).maybeSingle();
  if (!p) return API('sendMessage', { chat_id: chatId, text: numero + ' no existe.' });
  const { data: g, error } = await db().from('garantias')
    .insert({ pedido_id: p.id, numero_pedido: numero, falla: falla.trim() }).select('id').single();
  if (error || !g) return API('sendMessage', { chat_id: chatId, text: 'No se pudo guardar la garantía. Intenta de nuevo.' });
  return API('sendMessage', {
    chat_id: chatId,
    text: '🛡️ Garantía registrada para ' + numero + ':\n“' + falla.trim() + '”\n\nCuando la soluciones, toca ✅ Resuelta.',
    reply_markup: BOTON_RESUELTA(g.id),
  });
}

async function marcarResuelta(cq, id) {
  const { data, error } = await db().from('garantias')
    .update({ estado: 'resuelta', resuelto_en: new Date().toISOString() })
    .eq('id', id).eq('estado', 'abierta').select('numero_pedido');
  if (error) return 'No se pudo marcar como resuelta. Intenta de nuevo.';
  await cambiarBotones(cq, SIN_BOTONES);
  if (!data || data.length === 0) return 'Esa garantía ya estaba resuelta.';
  return 'Garantía de ' + data[0].numero_pedido + ' resuelta.';
}

async function listarGarantias(chatId) {
  const { data } = await db().from('garantias').select('id,numero_pedido,falla,creado_en')
    .eq('estado', 'abierta').order('creado_en', { ascending: true });
  if (!data || data.length === 0) return API('sendMessage', { chat_id: chatId, text: 'No tienes garantías abiertas 🎉' });
  for (const g of data) {
    const dias = diasDesde(g.creado_en);
    const alerta = dias > DIAS_GARANTIA ? ' ⚠️ más de ' + DIAS_GARANTIA + ' días' : '';
    await API('sendMessage', {
      chat_id: chatId,
      text: '🛡️ ' + g.numero_pedido + ' · abierta hace ' + dias + ' día(s)' + alerta + '\nFalla: ' + g.falla,
      reply_markup: BOTON_RESUELTA(g.id),
    });
  }
}

const AYUDA = 'Comandos:\n/garantias → ver garantías abiertas\n/garantia INZ-1234 → registrar una garantía de un pedido';

Deno.serve(async (req) => {
  const url = new URL(req.url);
  // Enlace de configuración: se abre una vez y registra el bot en Telegram con la clave nueva
  if (req.method === 'GET' && url.searchParams.get('configurar') === '1') {
    if (!SECRETO) return new Response('falta el secreto TELEGRAM_WEBHOOK_SECRET', { status: 500 });
    const r = await API('setWebhook', { url: WEBHOOK_URL, secret_token: SECRETO, allowed_updates: ['message', 'callback_query'] });
    return new Response(JSON.stringify({ configurado: r.ok === true, respuesta: r }, null, 2), { headers: { 'Content-Type': 'application/json' } });
  }
  if (!SECRETO || req.headers.get('x-telegram-bot-api-secret-token') !== SECRETO) return new Response('no autorizado', { status: 401 });
  if (!TOKEN()) return new Response('falta TELEGRAM_BOT_TOKEN', { status: 500 });

  const u = await req.json().catch(() => ({}));

  const cq = u?.callback_query;
  if (cq) {
    const chatId = cq.message?.chat?.id;
    let texto = 'Botón no reconocido.';
    if (!chatId || !(await esRegistrado(chatId))) texto = 'No autorizado.';
    else {
      const [accion, valor] = String(cq.data || '').split(':');
      if (valor && (accion === 'pagado' || accion === 'confirmar')) texto = await marcarPagado(cq, valor);
      else if (valor && accion === 'entregado') texto = await marcarEntregado(cq, valor);
      else if (valor && accion === 'garantia') texto = await pedirFalla(chatId, valor);
      else if (valor && accion === 'resuelta') texto = await marcarResuelta(cq, valor);
    }
    await API('answerCallbackQuery', { callback_query_id: cq.id, text: texto });
    return new Response('ok');
  }

  const msg = u?.message;
  const chatId = msg?.chat?.id;
  if (!chatId) return new Response('ok');
  if (!(await esRegistrado(chatId))) {
    await API('sendMessage', { chat_id: chatId, text: 'Hola, gracias por escribir.' });
    return new Response('ok');
  }

  const texto = String(msg.text || '').trim();
  const pregunta = String(msg.reply_to_message?.text || '');
  const enRespuesta = pregunta.match(/Garantía (INZ-\d+)/);

  if (enRespuesta && pregunta.includes('falla tiene') && texto) {
    await registrarGarantia(chatId, enRespuesta[1], texto);
  } else if (/^\/garantias\b/i.test(texto)) {
    await listarGarantias(chatId);
  } else if (/^\/garantia\b/i.test(texto)) {
    const m = texto.toUpperCase().match(/INZ-\d+/);
    if (m) await pedirFalla(chatId, m[0]);
    else await API('sendMessage', { chat_id: chatId, text: 'Escribe el número del pedido, por ejemplo: /garantia INZ-1015' });
  } else {
    await API('sendMessage', { chat_id: chatId, text: AYUDA });
  }
  return new Response('ok');
});
