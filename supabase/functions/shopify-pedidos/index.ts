// Recibe los avisos de pedidos de la tienda Shopify de Inizitech y los guarda en la base de datos.
// Shopify llama a: https://<proyecto>.supabase.co/functions/v1/shopify-pedidos?token=CLAVE
// La CLAVE NO va en el código: está en el secreto SHOPIFY_CLAVE de Supabase.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CLAVE = Deno.env.get('SHOPIFY_CLAVE') ?? '';
const TIENDA = 'tzsafm-de.myshopify.com';

const db = () => createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const responder = (texto: string, status = 200) => new Response(texto, { status });

Deno.serve(async (req) => {
  if (!CLAVE) return responder('falta el secreto SHOPIFY_CLAVE', 500);
  if (req.method !== 'POST') return responder('solo POST', 405);

  const url = new URL(req.url);
  if (url.searchParams.get('token') !== CLAVE) return responder('no autorizado', 401);

  const tienda = req.headers.get('x-shopify-shop-domain');
  if (tienda && tienda !== TIENDA) return responder('tienda no reconocida', 403);

  const tema = req.headers.get('x-shopify-topic') ?? 'orders/create';
  const pedido = await req.json().catch(() => null);
  if (!pedido?.id) return responder('sin pedido', 400);

  try {
    if (tema === 'orders/paid') {
      const { error } = await db().rpc('marcar_pagado_shopify', { p_shopify_id: String(pedido.id) });
      if (error) throw error;
      // Si el pedido aún no existía, se crea (ya viene como pagado)
      const { data, error: e2 } = await db().rpc('registrar_pedido_shopify', { p: pedido });
      if (e2) throw e2;
      console.log('pagado', pedido.name, data);
      return responder('ok ' + data);
    }
    const { data, error } = await db().rpc('registrar_pedido_shopify', { p: pedido });
    if (error) throw error;
    console.log('guardado', pedido.name, data);
    return responder('ok ' + data);
  } catch (e) {
    // Se responde 200 para que Shopify no reintente sin fin; el error queda en los registros.
    console.error('no se pudo guardar', pedido?.name, (e as Error)?.message ?? e);
    return responder('omitido: ' + ((e as Error)?.message ?? 'error'), 200);
  }
});
