# Operación de la prueba gratuita

Este procedimiento cubre la prueba de dos meses del backend de nube y ranking
casual. Supabase se usa solo como PostgreSQL, Render aloja la API y Resend envía
el correo transaccional. No guarda secretos, URLs privadas ni copias de
producción en el repositorio.

## Artefactos y registro

El repositorio conserva este procedimiento y
`scripts/operations/export-database.sh`. El repositorio del backend debe
conservar, antes de desplegar, el manifiesto de despliegue reproducible, las
migraciones versionadas, `.env.example` sin valores y el endpoint autenticado
`GET /health`.

El responsable guarda fuera del repositorio, en un gestor de secretos:

- el identificador del proyecto de Supabase, el enlace al panel y la cadena de
  conexión de mantenimiento;
- la URL del servicio de Render, su panel, el repositorio y el SHA desplegado;
- el dominio verificado de Resend, el panel y las claves de API con permiso
  mínimo de envío;
- la ubicación cifrada de cada archivo de respaldo, su fecha y el SHA del
  backend al que corresponde.

Las variables de Render incluyen la conexión a PostgreSQL y la clave de
Resend. No se escriben en archivos de configuración, incidencias, registros ni
salida de terminal. Render no puede alojar datos persistentes de la aplicación:
su sistema de archivos se pierde al reiniciar, redesplegar o suspender una
instancia gratuita.

## Antes de abrir la prueba

1. Aplicar las migraciones desde el repositorio del backend y registrar su SHA.
2. Configurar el dominio de Resend, publicar los registros DNS requeridos y
   comprobar que figura como verificado. Crear una clave de *Sending access* y
   configurarla únicamente en Render.
3. Configurar en Render la URL de PostgreSQL, las claves de sesión y la clave
   de Resend como variables secretas. Desplegar desde un SHA identificable y
   comprobar `GET /health`.
4. Probar registro, correo de recuperación, inicio de sesión, carga de una
   partida y consulta del ranking en una cuenta de prueba.
5. Ejecutar una exportación con el script, guardar el archivo fuera del
   repositorio y validar que `pg_restore --list` termina correctamente.

## Ritmo de operación

Cada semana, y antes de cualquier migración o cambio de proveedor:

1. Comprobar `GET /health`, el panel de Supabase, el despliegue activo de
   Render y la verificación del dominio en Resend.
2. Crear una copia cifrada con el script y registrar la ubicación, fecha y SHA
   del backend en el gestor de secretos.
3. Revisar errores de autenticación, envío de correo, límite de uso y
   conexiones fallidas. Rotar o revocar una clave expuesta antes de continuar.

Una instancia gratuita de Render se suspende tras 15 minutos sin tráfico; la
primera petición posterior puede tardar aproximadamente un minuto. El cliente
debe mostrar ese estado como conexión pendiente, no como una sincronización
completada. La prueba no depende de mantener despierto el servicio.

## Recuperación

### Servicio de Render suspendido o reiniciado

1. Solicitar `GET /health` y esperar el arranque.
2. Si no responde, revisar los registros y redesplegar el último SHA
   conocido; un rollback solo se usa si el despliegue actual es la causa.
3. Confirmar que la API usa las variables secretas configuradas y realizar el
   recorrido de prueba mínimo. No reconstruir datos desde el sistema de
   archivos de Render.

### Proyecto de Supabase pausado o sustituido

1. Recuperar el proyecto desde el panel de Supabase cuando siga disponible.
2. Si debe crearse un proyecto nuevo, restaurar la última exportación en él,
   volver a aplicar la configuración externa necesaria (extensiones,
   publicaciones y secretos) y actualizar la variable de conexión de Render.
3. Ejecutar una prueba de inicio de sesión, lectura y escritura con una cuenta
   de prueba antes de redirigir tráfico real.

Una restauración de base de datos no reconstituye por sí sola la configuración
de Render, Resend, DNS, secretos ni otros ajustes del panel de Supabase; el
registro externo de la primera sección es obligatorio para recuperarlos.

## Exportar y comprobar una copia

En un equipo de administración con `pg_dump` y `pg_restore` instalados, cargar
la cadena de conexión de mantenimiento en una variable de entorno y elegir una
ruta fuera del repositorio:

```bash
export DATABASE_URL='postgresql://...'
scripts/operations/export-database.sh /ruta/cifrada/dungeon-critters-YYYY-MM-DD.dump
```

El script crea un archivo de formato personalizado de PostgreSQL, verifica que
se puede leer y asigna permisos de propietario. No sustituye una copia
existente. Para ensayar una restauración, crear un destino temporal y usar
`pg_restore` según la guía vigente de Supabase; no restaurar sobre producción
sin una decisión explícita de recuperación.

## Cierre a los dos meses

1. Crear y verificar una exportación final.
2. Guardar la ubicación de la copia final y el SHA desplegado en el gestor de
   secretos.
3. Decidir explícitamente si se continúa con un plan de pago, se migra o se
   desactiva el servicio. Antes de desactivar, informar a los participantes de
   la fecha de corte y de la disponibilidad de sus datos.
4. Revocar las claves de Render, Supabase y Resend que ya no sean necesarias.

## Referencias operativas

- [Supabase: copia y restauración con CLI](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)
- [Supabase: recuperación de un proyecto pausado](https://supabase.com/kb/troubleshooting/restore-project-after-90-days-pause)
- [Render: despliegue gratuito](https://render.com/docs/free)
- [Resend: crear una clave de API](https://resend.com/docs/create-an-api-key)
- [Resend: verificar un dominio](https://resend.com/docs/api-reference/domains/verify-domain)
