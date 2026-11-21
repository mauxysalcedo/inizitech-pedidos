import { createClient } from 'npm:@supabase/supabase-js@2';

// Recordatorio diario de cumpleaños por Telegram.
// Cada mañana (7:00 a. m. hora de Colombia) la base llama a esta función. Si hoy cumple años algún
// cliente que autorizó el tratamiento de datos, manda a Telegram la lista con un botón por cliente
// que abre WhatsApp con el saludo ya escrito. No se necesita dominio ni correo.
//
// Protecciones (la función es pública porque la llama la base sin clave):
//  - Solo actúa entre las 7:00 y las 9:59 a. m. de Colombia.
//  - Solo envía una vez por día (tabla recordatorios_enviados).
//  - No devuelve datos de clientes en su respuesta.
// Secretos usados: TELEGRAM_BOT_TOKEN.

const ZONA = 'America/Bogota';
const HORA_UTC_DESDE = 12; // 7:00 a. m. Colombia
const HORA_UTC_HASTA = 14; // hasta 9:59 a. m. Colombia

const TOKEN = () => Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const API = (metodo, datos) => fetch(`https://api.telegram.org/bot${TOKEN()}/${metodo}`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(datos),
}).then(r => r.json());
const db = () => createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });

const fechaColombia = (d = new Date()) => d.toLocaleDateString('en-CA', { timeZone: ZONA }); // AAAA-MM-DD
const esBisiesto = (y) => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;

// Clientes que cumplen años en la fecha dada (AAAA-MM-DD). El 29 de febrero se celebra el 28 en años no bisiestos.
const cumpleanerosDe = (clientes, fechaHoy) => {
  const [anio, mes, dia] = fechaHoy.split('-');
  const hoy = mes + '-' + dia;
  const incluir29 = hoy === '02-28' && !esBisiesto(Number(anio));
  return (clientes || []).filter(c => {
    const md = String(c.fecha_nacimiento || '').slice(5, 10);
    return md === hoy || (incluir29 && md === '02-29');
  });
};

const primerNombre = (nombre) => {
  const p = String(nombre || '').trim().split(/\s+/)[0] || '';
  return p.charAt(0).toUpperCase() + p.slice(1).toLowerCase();
};

// Número para wa.me: solo dígitos y con indicativo de Colombia si viene de 10 dígitos.
const digitosWhatsapp = (celular) => {
  const d = String(celular || '').replace(/\D/g, '');
  return d.length === 10 ? '57' + d : d;
};

const saludo = (nombre) =>
  '¡Feliz cumpleaños, ' + primerNombre(nombre) + '! 🎉 De parte de Inizitech te deseamos un día muy especial. ' +
  'Gracias por ser parte de nuestros clientes. 💛';

const armarMensaje = (lista) => {
  const lineas = lista.map(c => '• ' + c.nombre + ' · ' + c.celular).join('\n');
  const text = '🎂 ' + (lista.length === 1 ? 'Hoy cumple años:' : 'Hoy cumplen años:') + '\n' + lineas +
    '\n\nToca el botón para abrir WhatsApp con el saludo ya escrito. Solo falta enviarlo.';
  const inline_keyboard = lista.map(c => [{
    text: '🎉 Felicitar a ' + primerNombre(c.nombre),
    url: 'https://wa.me/' + digitosWhatsapp(c.celular) + '?text=' + encodeURIComponent(saludo(c.nombre)),
  }]);
  return { text, reply_markup: { inline_keyboard } };
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

    const hoy = fechaColombia(ahora);
    const { data: clientes, error } = await db().from('clientes')
      .select('nombre,celular,fecha_nacimiento')
      .eq('autoriza_datos', true)
      .not('fecha_nacimiento', 'is', null);
    if (error) return json({ enviado: false, motivo: 'error al leer clientes' }, 500);

    const lista = cumpleanerosDe(clientes, hoy);
    if (lista.length === 0) return json({ enviado: false, motivo: 'hoy no hay cumpleaños' });

    const chats = await chatsRegistrados();
    if (chats.length === 0) return json({ enviado: false, motivo: 'sin contactos de Telegram' });

    // Reclamar el día: si ya se envió hoy, no se repite.
    const { error: eReclamo } = await db().from('recordatorios_enviados').insert({ tipo: 'cumpleanos', fecha: hoy });
    if (eReclamo) {
      if (eReclamo.code === '23505') return json({ enviado: false, motivo: 'ya se envió hoy' });
      return json({ enviado: false, motivo: 'error al registrar el envío' }, 500);
    }

    const { text, reply_markup } = armarMensaje(lista);
    let enviados = 0;
    for (const chat_id of chats) {
      const r = await API('sendMessage', { chat_id, text, reply_markup });
      if (r.ok) enviados++;
    }
    // Si no salió a ningún chat, se libera el día para poder reintentar.
    if (enviados === 0) await db().from('recordatorios_enviados').delete().eq('tipo', 'cumpleanos').eq('fecha', hoy);
    return json({ enviado: enviados > 0, cumpleaneros: lista.length, chats: enviados });
  } catch (e) {
    return json({ enviado: false, motivo: 'error: ' + e.message }, 500);
  }
});
