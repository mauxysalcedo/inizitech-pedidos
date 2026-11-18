-- =====================================================================
-- INIZI TECH · Lectura pública segura
-- El público (anon) puede leer solo los productos activos y solo las
-- columnas públicas (sin costo). Los domicilios por municipio también
-- son públicos, porque la página los muestra.
-- =====================================================================

-- Productos activos visibles para el público (RLS)
create policy productos_lectura_publica on public.productos
  for select to anon, authenticated
  using (activo);

-- Columnas públicas únicamente: "costo" NUNCA se expone
revoke select on public.productos from anon, authenticated;
grant select (id, slug, nombre, descripcion, categoria, precio, precio_antes,
              foto_url, opciones, es_combo, destacado, orden, activo)
  on public.productos to anon, authenticated;

-- La vista ya no usa permisos del dueño: usa los del que consulta
alter view public.productos_publicos set (security_invoker = true);

-- Domicilios por municipio: solo activos y solo lectura
create policy zonas_lectura_publica on public.zonas_domicilio
  for select to anon, authenticated
  using (activo);
grant select on public.zonas_domicilio to anon, authenticated;

-- "Lo más pedido" en la página = destacado
update public.productos
   set destacado = (slug in ('airpods-pro-2','airpods-pro-3','cargador-20w',
                              'cable-lightning','combo-2-relojes'));
