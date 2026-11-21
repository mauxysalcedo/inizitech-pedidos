import { createClient } from 'npm:@supabase/supabase-js@2';

// Recordatorio diario por Telegram de los pedidos que siguen pendientes de pago.
// Evita que un pedido que ya se pagó, pero no se marcó, se cancele solo a las 48 horas.
// Cada mañana (7:00 a. m. hora de Colombia) la base llama a esta función. Manda un mensaje por pedido
// con el botón 💰 Pagado (lo atiende la función telegram-webhook, igual que las alertas).
//
// Protecciones (la función es pública porque la llama la base sin clave):
//  - Solo actúa entre las 7:00 y las 9:59 a. m. de Colombia.
//  - Solo envía una vez por día (tabla recordatorios_enviados).
//  - No devuelve datos de clientes en su respuesta.
// Secretos usados: TELEGRAM_BOT_TOKEN.

const ZONA = 'America/Bogota';
const HORA_UTC_DESDE = 12; // 7:00 a. m. Colombia
const HORA_UTC_HASTA = 14; // hasta 9:59 a. m. Colombia
const MINIMO_HORAS = 2;    // no se avisan pedidos recién hechos
const CANCELA_A_LAS = 48;  // horas (igual que la tarea cancelar-pedidos-pendientes)
const AVISAR_DESDE = 24;   // desde esas horas se marca que se cancelará pronto
const MAXIMO = 10;         // máximo de mensajes por día

const NOMBRE_PAGO = { contado: 'Efectivo', transferencia: 'Transferencia', sistecredito: 'Sistecrédito', bold: 'Bold (pago en línea)' };

const TOKEN = () => Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const API = (metodo, datos) => fetch(`https://api.telegram.org/bot${TOKEN()}/${metodo}`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(datos),
}).then(r => r.json());
const db = () => createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });

const fechaColombia = (d = new Date()) => d.toLocaleDateString('en-CA', { timeZone: ZONA }); // AAAA-MM-DD
const dinero = (n) => '$ ' + Math.round(n).toLocaleString('es-CO');
const horasDesde = (fechaIso, ahora) => Math.floor((ahora.getTime() - new Date(fechaIso).getTime()) / 3600000);

// "hace 5 h" / "hace 1 día y 3 h"
const textoEdad = (horas) => {
  if (horas < 24) return 'hace ' + horas + ' h';
  const dias = Math.floor(horas / 24);
  const resto = horas % 24;
  return 'hace ' + dias + (dias === 1 ? ' día' : ' días') + (resto ? ' y ' + resto + ' h' : '');
};

// Mensaje y botón de un pedido pendiente.
const armarPedido = (p, ahora) => {
  const horas = horasDesde(p.creado_en, ahora);
  const restan = Math.max(CANCELA_A_LAS - horas, 0);
  const cliente = Array.isArray(p.clientes) ? p.clientes[0] : p.clientes;
  const aviso = horas >= AVISAR_DESDE
    ? '\n⚠️ Se cancela solo en ' + (restan <= 1 ? 'menos de 1 h' : restan + ' h') + ' si no lo marcas como pagado.'
    : '';
  const text = '⏳ ' + p.numero + ' · pendiente de pago\n' +
    (cliente?.nombre ?? 'Cliente') + ' · ' + dinero(p.total) + ' · ' + (NOMBRE_PAGO[p.forma_pago] ?? p.forma_pago) +
    '\n' + textoEdad(horas) + aviso;
  return { text, reply_markup: { inline_keyboard: [[{ text: '💰 Pagado', callback_data: 'pagado:' + p.numero }]] } };
};

// Lista de mensajes: un encabezado y un mensaje por pedido (los más antiguos primero, con tope).
const armarMensajes = (pedidos, ahora) => {
  const ordenados = [...(pedidos || [])].sort((a, b) => new Date(a.creado_en) - new Date(b.creado_en));
  const mostrados = ordenados.slice(0, MAXIMO);
  const resto = ordenados.length - mostrados.length;
  const encabezado = '⏳ Pedidos pendientes de pago: ' + ordenados.length +
    (resto > 0 ? '\nTe muestro los ' + MAXIMO + ' más antiguos. Quedan ' + resto + ' más.' : '') +
    '\nSi ya te pagaron, toca 💰 Pagado. A las ' + CANCELA_A_LAS + ' h sin pago se cancelan solos.';
  return [{ text: encabezado }, ...mostrados.map(p => armarPedido(p, ahora))];
};

const chatsRegistrados = async () => {
  const { data } = await db().from('telegram_contactos').select('chat_id');
  return (data || []).map(c => String(c.chat_id));
};

Deno.serve(async () => {
  try {
    const ahora = new Date();
    const hora = ahora.getUTCHours();
    if (hora < HORA_UTC_DESDE || hora > HORA_UTC_HASTA) return json({ enviado: false, motivo: 'fuera de horario' });
    if (!TOKEN()) return json({ enviado: false, motivo: 'falta TELEGRAM_BOT_TOKEN' }, 500);

    const limite = new Date(ahora.getTime() - MINIMO_HORAS * 3600000).toISOString();
    const { data: pedidos, error } = await db().from('pedidos')
      .select('numero,total,forma_pago,creado_en,clientes(nombre)')
      .eq('estado', 'pendiente')
      .lt('creado_en', limite);
    if (error) return json({ enviado: false, motivo: 'error al leer pedidos' }, 500);
    if (!pedidos || pedidos.length === 0) return json({ enviado: false, motivo: 'no hay pedidos pendientes' });

    const chats = await chatsRegistrados();
    if (chats.length === 0) return json({ enviado: false, motivo: 'sin contactos de Telegram' });

    // Reclamar el día: si ya se envió hoy, no se repite.
    const hoy = fechaColombia(ahora);
    const { error: eReclamo } = await db().from('recordatorios_enviados').insert({ tipo: 'pendientes', fecha: hoy });
    if (eReclamo) {
      if (eReclamo.code === '23505') return json({ enviado: false, motivo: 'ya se envió hoy' });
      return json({ enviado: false, motivo: 'error al registrar el envío' }, 500);
    }

    const mensajes = armarMensajes(pedidos, ahora);
    let chatsOk = 0;
    for (const chat_id of chats) {
      let ok = true;
      for (const m of mensajes) {
        const r = await API('sendMessage', { chat_id, ...m });
        if (!r.ok) ok = false;
      }
      if (ok) chatsOk++;
    }
    // Si no salió a ningún chat, se libera el día para poder reintentar.
    if (chatsOk === 0) await db().from('recordatorios_enviados').delete().eq('tipo', 'pendientes').eq('fecha', hoy);
    return json({ enviado: chatsOk > 0, pedidos: pedidos.length, chats: chatsOk });
  } catch (e) {
    return json({ enviado: false, motivo: 'error: ' + e.message }, 500);
  }
});
