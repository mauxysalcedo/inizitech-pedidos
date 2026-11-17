-- =====================================================================
-- INIZI TECH · Base de datos única (fuente de verdad)
-- Proyecto Supabase: "inizitech's Project"
--
-- Qué hace esta migración (en palabras simples):
--   1. Crea las tablas: productos, clientes, pedidos, detalle_pedido,
--      codigos_descuento e intentos_envio (esta última es para anti-spam).
--   2. Crea el consecutivo de pedidos INZ-1000, INZ-1001, ...
--   3. Crea las vistas: productos_publicos (lo que ve la gente) y
--      resumen_ventas, cumpleanos_del_mes, oportunidades_seguimiento
--      (solo para la dueña / Power BI).
--   4. Cierra la seguridad: el público NO lee ni escribe tablas; solo
--      lee productos_publicos y llama a dos funciones: crear_pedido y
--      registrar_cliente.
--   5. Programa la cancelación automática de pedidos pendientes (48 h).
--   6. Carga los productos y combos que hoy están en la página.
--
-- Moneda: pesos colombianos (COP), sin decimales. Zona horaria: America/Bogota.
-- =====================================================================

create extension if not exists pg_cron with schema pg_catalog;


-- ---------------------------------------------------------------------
-- 1. FUNCIONES AUXILIARES
-- ---------------------------------------------------------------------

-- Convierte cualquier forma de escribir un celular colombiano a +57XXXXXXXXXX.
-- Acepta: 3045621589 | 304 562 1589 | +57 304 562 1589 | 573045621589
-- Devuelve NULL si no es un celular colombiano válido (empieza en 3, 10 dígitos).
create or replace function public.normalizar_celular(p text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when d ~ '^3[0-9]{9}$'     then '+57' || d
    when d ~ '^573[0-9]{9}$'   then '+' || d
    else null
  end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;

-- Mantiene al día la columna "actualizado_en".
create or replace function public.set_actualizado_en()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.actualizado_en := now();
  return new;
end
$$;

-- Respuesta de error uniforme para las funciones públicas.
create or replace function public._error(p_codigo text, p_mensaje text)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object('ok', false, 'codigo', p_codigo, 'mensaje', p_mensaje)
$$;


-- ---------------------------------------------------------------------
-- 2. TABLAS
-- ---------------------------------------------------------------------

-- ---- productos -------------------------------------------------------
create table public.productos (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique
                  check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  nombre        text not null check (length(trim(nombre)) > 0),
  descripcion   text,
  categoria     text not null
                  check (categoria in ('audio','relojes','cargadores','accesorios','combos')),
  precio        integer not null check (precio >= 0),
  precio_antes  integer check (precio_antes is null or precio_antes > precio),
  costo         integer check (costo is null or costo >= 0),
  foto_url      text,
  opciones      jsonb not null default '[]'::jsonb
                  check (jsonb_typeof(opciones) = 'array'),
  es_combo      boolean not null default false,
  destacado     boolean not null default false,
  activo        boolean not null default true,
  orden         integer not null default 100,
  creado_en     timestamptz not null default now()
);
comment on table  public.productos is 'Catálogo único. La gente NO lee esta tabla: lee la vista productos_publicos.';
comment on column public.productos.costo is 'PRIVADO. Lo que te cuesta el producto; sirve para calcular el margen.';
comment on column public.productos.precio_antes is 'Solo si fue un precio real anterior (se muestra tachado).';
comment on column public.productos.opciones is
  'Lo que el cliente debe elegir. Lista de objetos: [{"clave":"color","etiqueta":"Color","obligatoria":true}]';

-- ---- codigos_descuento ----------------------------------------------
create table public.codigos_descuento (
  codigo      text primary key check (codigo = upper(codigo) and length(codigo) between 3 and 30),
  porcentaje  integer not null check (porcentaje between 1 and 100),
  activo      boolean not null default true,
  vence_en    timestamptz
);
comment on table public.codigos_descuento is 'Códigos de descuento (ej. INIZI10 = 10%). Se manejan desde aquí, no desde el código de la página.';

-- ---- clientes --------------------------------------------------------
create table public.clientes (
  id                  uuid primary key default gen_random_uuid(),
  nombre              text not null check (length(trim(nombre)) > 0),
  celular             text not null unique check (celular ~ '^\+57[0-9]{10}$'),
  email               text check (email is null or (
                        email = lower(email)
                        and email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$')),
  municipio           text,
  barrio              text,
  origen              text not null default 'pagina'
                        check (origen in ('pagina','formulario','google_forms','agente','manual')),
  intereses           text,
  fecha_nacimiento    date check (fecha_nacimiento is null or fecha_nacimiento >= date '1900-01-01'),
  autoriza_datos      boolean not null default false,
  fecha_autorizacion  timestamptz,
  notas_internas      text,
  ultima_compra       timestamptz,
  total_comprado      integer not null default 0,
  creado_en           timestamptz not null default now(),
  actualizado_en      timestamptz not null default now()
);
comment on column public.clientes.notas_internas is 'PRIVADO. Lo que tú sabes del cliente.';
comment on column public.clientes.ultima_compra   is 'Se calcula solo (pedidos confirmados o entregados).';
comment on column public.clientes.total_comprado  is 'Se calcula solo (pedidos confirmados o entregados).';

create trigger trg_clientes_actualizado
  before update on public.clientes
  for each row execute function public.set_actualizado_en();

-- ---- pedidos ---------------------------------------------------------
create sequence public.pedidos_numero_seq start with 1000 minvalue 1000;

create table public.pedidos (
  id                 uuid primary key default gen_random_uuid(),
  numero             text not null unique
                       default ('INZ-' || nextval('public.pedidos_numero_seq')),
  cliente_id         uuid not null references public.clientes(id) on delete restrict,
  subtotal           integer not null check (subtotal >= 0),
  descuento          integer not null default 0 check (descuento >= 0),
  codigo_descuento   text references public.codigos_descuento(codigo),
  costo_envio        integer not null default 0 check (costo_envio >= 0),
  total              integer not null check (total >= 0),
  forma_pago         text not null
                       check (forma_pago in ('contado','transferencia','sistecredito')),
  cuotas             integer check (cuotas is null or cuotas between 1 and 36),
  estado             text not null default 'pendiente'
                       check (estado in ('pendiente','confirmado','entregado','cancelado')),
  estado_pago        text not null default 'pendiente'
                       check (estado_pago in ('pendiente','pagado')),
  direccion_entrega  text,
  notas              text,
  canal              text not null default 'pagina'
                       check (canal in ('pagina','web','agente_whatsapp','agente_instagram','manual')),
  utm_source         text,
  utm_medium         text,
  utm_content        text,
  fecha_entrega      date,
  motivo_cancelacion text,
  creado_en          timestamptz not null default now(),
  actualizado_en     timestamptz not null default now()
);
alter sequence public.pedidos_numero_seq owned by public.pedidos.numero;
comment on column public.pedidos.numero is 'Consecutivo legible: INZ-1000, INZ-1001...';

create index idx_pedidos_cliente on public.pedidos(cliente_id);
create index idx_pedidos_estado_creado on public.pedidos(estado, creado_en);

create trigger trg_pedidos_actualizado
  before update on public.pedidos
  for each row execute function public.set_actualizado_en();

-- ---- detalle_pedido --------------------------------------------------
create table public.detalle_pedido (
  id               uuid primary key default gen_random_uuid(),
  pedido_id        uuid not null references public.pedidos(id) on delete cascade,
  producto_id      uuid not null references public.productos(id) on delete restrict,
  nombre_producto  text not null,
  cantidad         integer not null check (cantidad > 0),
  precio_unitario  integer not null check (precio_unitario >= 0),
  costo_unitario   integer check (costo_unitario is null or costo_unitario >= 0),
  especificaciones jsonb not null default '{}'::jsonb
);
comment on column public.detalle_pedido.nombre_producto  is 'Copia del nombre al momento de vender: el historial no cambia si luego renombras el producto.';
comment on column public.detalle_pedido.costo_unitario   is 'Copia del costo al momento de vender: el margen histórico no cambia si luego cambias el costo.';

create index idx_detalle_pedido on public.detalle_pedido(pedido_id);
create index idx_detalle_producto on public.detalle_pedido(producto_id);

-- ---- intentos_envio (anti-spam, uso interno) ------------------------
create table public.intentos_envio (
  id         bigint generated always as identity primary key,
  celular    text not null,
  tipo       text not null,
  creado_en  timestamptz not null default now()
);
create index idx_intentos_celular on public.intentos_envio(celular, creado_en);


-- ---------------------------------------------------------------------
-- 3. REGLA: estadísticas del cliente (se calculan solas)
-- ---------------------------------------------------------------------
create or replace function public.actualizar_stats_cliente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.clientes c
     set ultima_compra  = s.ultima,
         total_comprado = s.total
    from (select max(creado_en)                  as ultima,
                 coalesce(sum(total), 0)::integer as total
            from public.pedidos
           where cliente_id = new.cliente_id
             and estado in ('confirmado','entregado')) s
   where c.id = new.cliente_id;
  return null;
end
$$;

create trigger trg_pedidos_stats
  after insert or update of estado, total, cliente_id on public.pedidos
  for each row execute function public.actualizar_stats_cliente();


-- ---------------------------------------------------------------------
-- 4. VISTAS
-- ---------------------------------------------------------------------

-- Lo ÚNICO que ve el público: productos activos, sin costo.
-- Combos primero, luego destacados, luego por "orden".
create or replace view public.productos_publicos as
select id, slug, nombre, descripcion, categoria,
       precio, precio_antes, foto_url, opciones, es_combo, destacado, orden
  from public.productos
 where activo
 order by es_combo desc, destacado desc, orden, nombre;

-- Ventas, costo histórico y margen por producto y por mes (Power BI).
-- Solo cuenta pedidos confirmados o entregados. "ventas" es el valor de las
-- líneas antes de descuentos del pedido. "lineas_sin_costo" te avisa cuántas
-- ventas no tienen costo cargado (su margen se vería inflado).
create or replace view public.resumen_ventas
with (security_invoker = true) as
select (date_trunc('month', p.creado_en at time zone 'America/Bogota'))::date as mes,
       d.producto_id,
       d.nombre_producto                                                     as producto,
       sum(d.cantidad)::integer                                               as unidades,
       sum(d.cantidad * d.precio_unitario)::bigint                            as ventas,
       sum(d.cantidad * coalesce(d.costo_unitario, 0))::bigint                as costo,
       sum(d.cantidad * (d.precio_unitario - coalesce(d.costo_unitario, 0)))::bigint as margen,
       round(100.0 * sum(d.cantidad * (d.precio_unitario - coalesce(d.costo_unitario, 0)))
             / nullif(sum(d.cantidad * d.precio_unitario), 0), 1)             as margen_pct,
       count(*) filter (where d.costo_unitario is null)::integer              as lineas_sin_costo
  from public.detalle_pedido d
  join public.pedidos p on p.id = d.pedido_id
 where p.estado in ('confirmado','entregado')
 group by 1, 2, 3;

-- Clientes que cumplen años este mes (hora Colombia), para saludo y descuento.
create or replace view public.cumpleanos_del_mes
with (security_invoker = true) as
select id as cliente_id, nombre, celular, email, fecha_nacimiento,
       extract(day from fecha_nacimiento)::integer as dia,
       autoriza_datos
  from public.clientes
 where fecha_nacimiento is not null
   and extract(month from fecha_nacimiento)
       = extract(month from (now() at time zone 'America/Bogota'))
 order by extract(day from fecha_nacimiento), nombre;

-- Clientes con autorización que aún no compran (ningún pedido confirmado o
-- entregado), clasificados en:
--   pedido_abandonado      -> su último pedido sigue pendiente hace más de 2 h, o fue cancelado
--   registrado_sin_compra  -> nunca crearon un pedido
create or replace view public.oportunidades_seguimiento
with (security_invoker = true) as
with ultimo as (
  select distinct on (p.cliente_id)
         p.cliente_id, p.estado, p.creado_en, p.numero,
         (select string_agg(d.nombre_producto, ', ' order by d.nombre_producto)
            from public.detalle_pedido d where d.pedido_id = p.id) as ultimo_producto
    from public.pedidos p
   order by p.cliente_id, p.creado_en desc
)
select c.id as cliente_id, c.nombre, c.celular, c.email, c.municipio,
       case when u.cliente_id is null then 'registrado_sin_compra'
            else 'pedido_abandonado' end        as tipo_lead,
       u.ultimo_producto,
       u.numero                                 as ultimo_pedido,
       c.intereses,
       c.creado_en                              as fecha_registro,
       u.creado_en                              as fecha_ultimo_pedido
  from public.clientes c
  left join ultimo u on u.cliente_id = c.id
 where c.autoriza_datos
   and not exists (select 1 from public.pedidos p
                    where p.cliente_id = c.id
                      and p.estado in ('confirmado','entregado'))
   and (u.cliente_id is null
        or u.estado = 'cancelado'
        or (u.estado = 'pendiente' and u.creado_en < now() - interval '2 hours'));


-- ---------------------------------------------------------------------
-- 5. FUNCIONES PÚBLICAS (RPC)
-- ---------------------------------------------------------------------

-- ---- crear_pedido ----------------------------------------------------
-- p_items = [{"slug":"fundas","cantidad":1,"especificaciones":{"modelo_celular":"iPhone 13","color":"negra"}}, ...]
-- Los PRECIOS Y COSTOS se toman de la tabla productos, nunca de lo que envía el navegador.
-- Devuelve {"ok":true,"numero":"INZ-1042","total":...} o {"ok":false,"codigo":...,"mensaje":...}.
create or replace function public.crear_pedido(
  p_nombre           text,
  p_celular          text,
  p_municipio        text,
  p_barrio           text,
  p_direccion        text,
  p_forma_pago       text,
  p_items            jsonb,
  p_autoriza_datos   boolean,
  p_email            text    default null,
  p_fecha_nacimiento date    default null,
  p_notas            text    default null,
  p_cuotas           integer default null,
  p_codigo_descuento text    default null,
  p_utm_source       text    default null,
  p_utm_medium       text    default null,
  p_utm_content      text    default null,
  p_canal            text    default 'pagina',
  p_website          text    default null      -- campo trampa (honeypot): debe llegar vacío
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_celular    text;
  v_nombre     text := nullif(trim(coalesce(p_nombre, '')), '');
  v_municipio  text := nullif(trim(coalesce(p_municipio, '')), '');
  v_barrio     text := nullif(trim(coalesce(p_barrio, '')), '');
  v_direccion  text := nullif(trim(coalesce(p_direccion, '')), '');
  v_email      text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_notas      text := nullif(trim(coalesce(p_notas, '')), '');
  v_item       jsonb;
  v_opc        jsonb;
  v_prod       public.productos%rowtype;
  v_cant       integer;
  v_valor      text;
  v_spec       jsonb;
  v_lineas     jsonb := '[]'::jsonb;
  v_subtotal   integer := 0;
  v_descuento  integer := 0;
  v_pct        integer;
  v_codigo     text := nullif(upper(trim(coalesce(p_codigo_descuento, ''))), '');
  v_total      integer;
  v_cliente_id uuid;
  v_pedido_id  uuid;
  v_numero     text;
begin
  -- Anti-spam 1: campo trampa. Una persona real nunca lo llena.
  if nullif(trim(coalesce(p_website, '')), '') is not null then
    return public._error('solicitud_invalida', 'No se pudo procesar la solicitud.');
  end if;

  -- Celular válido y normalizado
  v_celular := public.normalizar_celular(p_celular);
  if v_celular is null then
    return public._error('celular_invalido', 'Escribe un celular colombiano válido de 10 dígitos (ej. 304 562 1589).');
  end if;

  -- Anti-spam 2: máximo 3 envíos cada 10 minutos por celular
  if (select count(*) from public.intentos_envio
       where celular = v_celular and creado_en > now() - interval '10 minutes') >= 3 then
    return public._error('demasiados_intentos', 'Has enviado varios pedidos seguidos. Espera unos minutos e inténtalo de nuevo.');
  end if;
  insert into public.intentos_envio (celular, tipo) values (v_celular, 'pedido');

  -- Validaciones de datos
  if v_nombre is null or length(v_nombre) > 100 then
    return public._error('nombre_invalido', 'Escribe tu nombre.');
  end if;
  if p_autoriza_datos is not true then
    return public._error('sin_autorizacion', 'Debes autorizar el tratamiento de tus datos personales para continuar.');
  end if;
  if v_municipio is null or v_barrio is null or length(v_municipio) > 80 or length(v_barrio) > 80 then
    return public._error('ubicacion_invalida', 'Escribe tu municipio y tu barrio.');
  end if;
  if v_direccion is null or length(v_direccion) < 5 or length(v_direccion) > 200 then
    return public._error('direccion_invalida', 'Escribe tu dirección de entrega.');
  end if;
  if p_forma_pago is null or p_forma_pago not in ('contado','transferencia','sistecredito') then
    return public._error('forma_pago_invalida', 'Elige una forma de pago.');
  end if;
  if p_canal is null or p_canal not in ('pagina','web') then
    return public._error('canal_invalido', 'Canal no permitido.');
  end if;
  if v_email is not null and v_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
    return public._error('email_invalido', 'El correo no parece válido.');
  end if;
  if p_fecha_nacimiento is not null
     and (p_fecha_nacimiento < date '1920-01-01' or p_fecha_nacimiento > current_date) then
    return public._error('fecha_invalida', 'La fecha de cumpleaños no es válida.');
  end if;
  if p_cuotas is not null and (p_forma_pago <> 'sistecredito' or p_cuotas not between 1 and 36) then
    return public._error('cuotas_invalidas', 'Las cuotas solo aplican con Sistecrédito (1 a 36).');
  end if;
  if v_notas is not null and length(v_notas) > 500 then
    return public._error('notas_largas', 'Las notas son muy largas (máximo 500 caracteres).');
  end if;

  -- Productos del pedido
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 20 then
    return public._error('pedido_vacio', 'Elige al menos un producto.');
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(v_item) <> 'object' then
      return public._error('producto_invalido', 'Producto inválido.');
    end if;

    select * into v_prod from public.productos
     where slug = v_item->>'slug' and activo;
    if not found then
      return public._error('producto_no_disponible', 'Uno de los productos ya no está disponible.');
    end if;

    begin
      v_cant := (v_item->>'cantidad')::integer;
    exception when others then
      v_cant := null;
    end;
    if v_cant is null or v_cant < 1 or v_cant > 10 then
      return public._error('cantidad_invalida', 'Máximo 10 unidades por producto: ' || v_prod.nombre || '.');
    end if;

    -- Opciones: se guardan solo las que el producto declara; las obligatorias deben venir completas.
    v_spec := '{}'::jsonb;
    for v_opc in select * from jsonb_array_elements(v_prod.opciones) loop
      v_valor := nullif(trim(coalesce(v_item->'especificaciones'->>(v_opc->>'clave'), '')), '');
      if v_valor is not null then
        if length(v_valor) > 80 then
          return public._error('opcion_invalida', 'Texto muy largo en: ' || (v_opc->>'etiqueta') || '.');
        end if;
        v_spec := v_spec || jsonb_build_object(v_opc->>'clave', v_valor);
      elsif coalesce((v_opc->>'obligatoria')::boolean, false) then
        return public._error('opcion_faltante',
          'Falta elegir: ' || coalesce(v_opc->>'etiqueta', v_opc->>'clave') || ' (' || v_prod.nombre || ').');
      end if;
    end loop;

    v_lineas := v_lineas || jsonb_build_array(jsonb_build_object(
      'producto_id', v_prod.id, 'slug', v_prod.slug, 'nombre', v_prod.nombre,
      'cantidad', v_cant, 'precio', v_prod.precio, 'costo', v_prod.costo, 'spec', v_spec));
    v_subtotal := v_subtotal + v_prod.precio * v_cant;
  end loop;

  -- Máximo 10 unidades por producto en total (aunque vengan en varias líneas)
  if exists (select 1 from jsonb_to_recordset(v_lineas) as l(slug text, cantidad integer)
              group by slug having sum(cantidad) > 10) then
    return public._error('cantidad_invalida', 'Máximo 10 unidades por producto.');
  end if;

  -- Código de descuento (opcional)
  if v_codigo is not null then
    select porcentaje into v_pct from public.codigos_descuento
     where codigo = v_codigo and activo and (vence_en is null or vence_en > now());
    if not found then
      return public._error('codigo_invalido', 'El código de descuento no es válido o ya venció.');
    end if;
    v_descuento := round(v_subtotal * v_pct / 100.0)::integer;
  end if;
  v_total := v_subtotal - v_descuento;

  -- Cliente: crea o actualiza por celular SIN borrar datos que ya existían
  insert into public.clientes
    (nombre, celular, email, municipio, barrio, origen, fecha_nacimiento, autoriza_datos, fecha_autorizacion)
  values
    (v_nombre, v_celular, v_email, v_municipio, v_barrio, 'pagina', p_fecha_nacimiento, true, now())
  on conflict (celular) do update set
    email              = coalesce(excluded.email,            public.clientes.email),
    municipio          = coalesce(excluded.municipio,        public.clientes.municipio),
    barrio             = coalesce(excluded.barrio,           public.clientes.barrio),
    fecha_nacimiento   = coalesce(excluded.fecha_nacimiento, public.clientes.fecha_nacimiento),
    autoriza_datos     = true,
    fecha_autorizacion = coalesce(public.clientes.fecha_autorizacion, excluded.fecha_autorizacion)
  returning id into v_cliente_id;

  -- Pedido + detalle (todo en la misma transacción)
  insert into public.pedidos
    (cliente_id, subtotal, descuento, codigo_descuento, total, forma_pago, cuotas,
     direccion_entrega, notas, canal, utm_source, utm_medium, utm_content)
  values
    (v_cliente_id, v_subtotal, v_descuento, v_codigo, v_total, p_forma_pago, p_cuotas,
     v_direccion, v_notas, p_canal,
     left(nullif(trim(p_utm_source), ''), 100),
     left(nullif(trim(p_utm_medium), ''), 100),
     left(nullif(trim(p_utm_content), ''), 200))
  returning id, numero into v_pedido_id, v_numero;

  for v_item in select * from jsonb_array_elements(v_lineas) loop
    insert into public.detalle_pedido
      (pedido_id, producto_id, nombre_producto, cantidad, precio_unitario, costo_unitario, especificaciones)
    values
      (v_pedido_id, (v_item->>'producto_id')::uuid, v_item->>'nombre',
       (v_item->>'cantidad')::integer, (v_item->>'precio')::integer,
       (v_item->>'costo')::integer, v_item->'spec');
  end loop;

  return jsonb_build_object('ok', true, 'numero', v_numero, 'total', v_total, 'descuento', v_descuento);
end
$$;

-- ---- registrar_cliente ----------------------------------------------
-- Para el formulario /registro (clientes antiguos). Devuelve el código de descuento activo.
create or replace function public.registrar_cliente(
  p_nombre           text,
  p_celular          text,
  p_municipio        text,
  p_barrio           text,
  p_autoriza_datos   boolean,
  p_email            text default null,
  p_intereses        text default null,
  p_fecha_nacimiento date default null,
  p_website          text default null         -- campo trampa (honeypot)
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_celular   text;
  v_nombre    text := nullif(trim(coalesce(p_nombre, '')), '');
  v_municipio text := nullif(trim(coalesce(p_municipio, '')), '');
  v_barrio    text := nullif(trim(coalesce(p_barrio, '')), '');
  v_email     text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_intereses text := nullif(trim(coalesce(p_intereses, '')), '');
  v_codigo    text;
begin
  if nullif(trim(coalesce(p_website, '')), '') is not null then
    return public._error('solicitud_invalida', 'No se pudo procesar la solicitud.');
  end if;

  v_celular := public.normalizar_celular(p_celular);
  if v_celular is null then
    return public._error('celular_invalido', 'Escribe un celular colombiano válido de 10 dígitos (ej. 304 562 1589).');
  end if;

  if (select count(*) from public.intentos_envio
       where celular = v_celular and creado_en > now() - interval '10 minutes') >= 3 then
    return public._error('demasiados_intentos', 'Has enviado varios registros seguidos. Espera unos minutos e inténtalo de nuevo.');
  end if;
  insert into public.intentos_envio (celular, tipo) values (v_celular, 'registro');

  if v_nombre is null or length(v_nombre) > 100 then
    return public._error('nombre_invalido', 'Escribe tu nombre.');
  end if;
  if p_autoriza_datos is not true then
    return public._error('sin_autorizacion', 'Debes autorizar el tratamiento de tus datos personales para continuar.');
  end if;
  if v_municipio is null or v_barrio is null or length(v_municipio) > 80 or length(v_barrio) > 80 then
    return public._error('ubicacion_invalida', 'Escribe tu municipio y tu barrio.');
  end if;
  if v_email is not null and v_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
    return public._error('email_invalido', 'El correo no parece válido.');
  end if;
  if p_fecha_nacimiento is not null
     and (p_fecha_nacimiento < date '1920-01-01' or p_fecha_nacimiento > current_date) then
    return public._error('fecha_invalida', 'La fecha de cumpleaños no es válida.');
  end if;
  if v_intereses is not null and length(v_intereses) > 300 then
    return public._error('intereses_largos', 'La lista de intereses es muy larga.');
  end if;

  insert into public.clientes
    (nombre, celular, email, municipio, barrio, origen, intereses, fecha_nacimiento, autoriza_datos, fecha_autorizacion)
  values
    (v_nombre, v_celular, v_email, v_municipio, v_barrio, 'formulario', v_intereses, p_fecha_nacimiento, true, now())
  on conflict (celular) do update set
    email              = coalesce(excluded.email,            public.clientes.email),
    municipio          = coalesce(excluded.municipio,        public.clientes.municipio),
    barrio             = coalesce(excluded.barrio,           public.clientes.barrio),
    intereses          = coalesce(excluded.intereses,        public.clientes.intereses),
    fecha_nacimiento   = coalesce(excluded.fecha_nacimiento, public.clientes.fecha_nacimiento),
    autoriza_datos     = true,
    fecha_autorizacion = coalesce(public.clientes.fecha_autorizacion, excluded.fecha_autorizacion);

  select codigo into v_codigo from public.codigos_descuento
   where codigo = 'INIZI10' and activo and (vence_en is null or vence_en > now());

  return jsonb_build_object('ok', true, 'codigo_descuento', v_codigo);
end
$$;


-- ---------------------------------------------------------------------
-- 6. SEGURIDAD: RLS + permisos
-- ---------------------------------------------------------------------

-- RLS encendido en TODAS las tablas. Sin políticas = el público no puede
-- leer ni escribir nada directamente. (Las funciones "security definer" y
-- tú desde el panel de Supabase sí pueden.)
alter table public.productos         enable row level security;
alter table public.clientes          enable row level security;
alter table public.pedidos           enable row level security;
alter table public.detalle_pedido    enable row level security;
alter table public.codigos_descuento enable row level security;
alter table public.intentos_envio    enable row level security;

-- Quitar los permisos que Supabase da por defecto al público...
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

-- ...y que las cosas nuevas que crees en el futuro también nazcan privadas.
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

-- Lo único que el público puede hacer:
grant usage on schema public to anon, authenticated;
grant select on public.productos_publicos to anon, authenticated;
grant execute on function public.crear_pedido(
  text, text, text, text, text, text, jsonb, boolean,
  text, date, text, integer, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.registrar_cliente(
  text, text, text, text, boolean, text, text, date, text) to anon, authenticated;


-- ---------------------------------------------------------------------
-- 7. TAREAS AUTOMÁTICAS (pg_cron)
-- ---------------------------------------------------------------------

-- Cada 15 minutos: los pedidos "pendiente" con más de 48 horas pasan a "cancelado".
select cron.schedule(
  'cancelar-pedidos-pendientes',
  '*/15 * * * *',
  $job$
    update public.pedidos
       set estado = 'cancelado',
           motivo_cancelacion = 'Vencido: sin confirmar en 48 horas'
     where estado = 'pendiente'
       and creado_en < now() - interval '48 hours'
  $job$
);

-- Cada día (3:00 a.m. Colombia): borra intentos anti-spam de más de 1 día.
select cron.schedule(
  'limpiar-intentos-envio',
  '0 8 * * *',
  $job$ delete from public.intentos_envio where creado_en < now() - interval '1 day' $job$
);


-- ---------------------------------------------------------------------
-- 8. DATOS INICIALES
-- ---------------------------------------------------------------------

insert into public.codigos_descuento (codigo, porcentaje) values ('INIZI10', 10);

-- "costo" queda vacío para que lo llenes tú. Los precios son los actuales de la página.
-- precio_antes solo en los AirPods Pro / Pro 2 (precio real de tu tienda web);
-- los combos no tienen precio_antes porque ese dato no era un precio real.
insert into public.productos
  (slug, nombre, descripcion, categoria, precio, precio_antes, opciones, es_combo, destacado, orden)
values
  -- Combos (aparecen primero)
  ('combo-flash-2-airpods', 'Combo flash: 2 AirPods Pro 2',
   'Llévate 2 AirPods Pro 2. Promoción por tiempo limitado.',
   'combos', 109000, null, '[]', true, false, 10),
  ('combo-airpods-reloj', 'Combo AirPods + reloj',
   'Dos de nuestros productos más vendidos en un solo combo.',
   'combos', 114999, null,
   '[{"clave":"color_reloj","etiqueta":"Color del reloj","obligatoria":true}]', true, false, 20),
  ('combo-2-relojes', 'Combo 2 relojes',
   '2 Watch Ultra 8 en un solo combo.',
   'combos', 110000, null,
   '[{"clave":"color_reloj_1","etiqueta":"Color del reloj 1","obligatoria":true},
     {"clave":"color_reloj_2","etiqueta":"Color del reloj 2","obligatoria":true}]', true, false, 30),
  ('combo-2-airpods-cargador', 'Combo 2 AirPods Pro 2 + cargador',
   '2 AirPods Pro 2 y un cargador completo. Ideal para regalar o compartir.',
   'combos', 134999, null, '[]', true, false, 40),
  ('combo-full', 'Combo full: AirPods + reloj + cargador',
   'Nuestro combo más completo: AirPods, reloj y cargador.',
   'combos', 139999, null,
   '[{"clave":"color_reloj","etiqueta":"Color del reloj","obligatoria":true}]', true, false, 50),
  -- Productos
  ('airpods-pro', 'AirPods Pro',
   'Cancelación de ruido, graves profundos y batería de larga duración.',
   'audio', 80000, 100000, '[]', false, true, 100),
  ('airpods-pro-2', 'AirPods Pro 2', null,
   'audio', 80000, 100000, '[]', false, false, 110),
  ('airpods-pro-3', 'AirPods Pro 3', null,
   'audio', 110000, null, '[]', false, false, 120),
  ('watch-ultra-8', 'Watch Ultra 8', null,
   'relojes', 65000, null,
   '[{"clave":"color","etiqueta":"Color del reloj","obligatoria":true}]', false, false, 200),
  ('cargador-20w', 'Cargador 20W-25W',
   'Carga rápida para iPhone: carga completa en 1 hora.',
   'cargadores', 60000, null, '[]', false, false, 300),
  ('cables-cargador', 'Cables de cargador', null,
   'cargadores', 20000, null, '[]', false, false, 310),
  ('fundas', 'Fundas para celular', null,
   'accesorios', 20000, null,
   '[{"clave":"modelo_celular","etiqueta":"Modelo de tu celular","obligatoria":true},
     {"clave":"color","etiqueta":"Color","obligatoria":true}]', false, false, 400);
