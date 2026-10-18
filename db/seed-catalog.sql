-- Unidades de ejemplo para ms-andesstay-catalog. Requiere que catalog haya arrancado al
-- menos una vez (Hibernate crea las tablas). Es idempotente: si el codigo ya existe, no
-- se vuelve a insertar. Uso:
--   docker exec -i andesstay-oracle sqlplus -s andesstay/changeit@FREEPDB1 < seed-catalog.sql
set define off
set feedback off

declare
  procedure unit(p_code varchar2, p_type varchar2, p_capacity number, p_rate number,
                 p_total number, p_amenities sys.odcivarchar2list) is
    v_id number;
    v_count number;
  begin
    select count(*) into v_count from catalog_units where code = p_code;
    if v_count > 0 then
      return;
    end if;
    insert into catalog_units (code, type, capacity, nightly_rate, total_units, available_units,
                               active, image_url, created_at, updated_at)
    values (p_code, p_type, p_capacity, p_rate, p_total, p_total,
            true, null, systimestamp, systimestamp)
    returning id into v_id;
    for i in 1 .. p_amenities.count loop
      insert into catalog_unit_amenities (unit_id, amenity) values (v_id, p_amenities(i));
    end loop;
  end;
begin
  unit('HAB-101', 'HABITACION', 2,  55000, 4, sys.odcivarchar2list('WIFI', 'DESAYUNO_INCLUIDO', 'CALEFACCION', 'VISTA_MONTANA'));
  unit('HAB-102', 'HABITACION', 3,  68000, 3, sys.odcivarchar2list('WIFI', 'DESAYUNO_INCLUIDO', 'CALEFACCION', 'TERRAZA'));
  unit('HAB-201', 'HABITACION', 2,  85000, 2, sys.odcivarchar2list('WIFI', 'DESAYUNO_INCLUIDO', 'JACUZZI', 'VISTA_LAGO'));
  unit('HAB-202', 'HABITACION', 4,  92000, 2, sys.odcivarchar2list('WIFI', 'DESAYUNO_INCLUIDO', 'CALEFACCION', 'VISTA_MONTANA', 'ESTACIONAMIENTO'));
  unit('CAB-01',  'CABANA',     4, 120000, 3, sys.odcivarchar2list('WIFI', 'COCINA_EQUIPADA', 'CHIMENEA', 'ESTACIONAMIENTO', 'ACCESO_SENDEROS'));
  unit('CAB-02',  'CABANA',     6, 165000, 2, sys.odcivarchar2list('WIFI', 'COCINA_EQUIPADA', 'CHIMENEA', 'TERRAZA', 'VISTA_LAGO', 'ESTACIONAMIENTO'));
  unit('CAB-03',  'CABANA',     4, 135000, 2, sys.odcivarchar2list('COCINA_EQUIPADA', 'PET_FRIENDLY', 'CALEFACCION', 'ACCESO_SENDEROS', 'ESTACIONAMIENTO'));
  unit('CAB-04',  'CABANA',     8, 210000, 1, sys.odcivarchar2list('WIFI', 'COCINA_EQUIPADA', 'CHIMENEA', 'JACUZZI', 'TERRAZA', 'VISTA_MONTANA', 'ESTACIONAMIENTO'));
  commit;
end;
/

set pages 100 lines 120
col code format a18
col type format a12
select code, type, capacity, nightly_rate, available_units from catalog_units order by code;
exit
