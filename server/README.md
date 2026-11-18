# Dungeon Critters API

La API es la única frontera entre el cliente y PostgreSQL/Supabase. El juego no
debe usar credenciales de Supabase ni conectarse directamente a la base de datos.

El despliegue requiere `DATABASE_URL`, `RESEND_API_KEY`, `RESEND_FROM_EMAIL` y,
opcionalmente, `PUBLIC_API_URL`. `RESEND_FROM_EMAIL` debe pertenecer a un dominio
verificado. Los secretos se configuran fuera del repositorio y no se escriben
en logs.

Los tests sustituyen Resend por un doble; no se ha enviado correo real. La
configuración externa de PostgreSQL, Resend y el dominio debe verificarse antes
del despliegue.

`test/server_migration_test.rb` solo comprueba estáticamente que el SQL declara
creación idempotente y las columnas de tokens esperadas. No aplica la migración
ni demuestra compatibilidad con una instancia PostgreSQL real.

Rutas: `POST /v1/accounts`, `POST /v1/accounts/verify-email`,
`POST /v1/sessions`, `POST /v1/sessions/refresh`,
`DELETE /v1/sessions/current` y `GET /v1/sessions/current`.

Argon2id usa formato PHC con `m=19456`, `t=2`, `p=1`. Los tokens se almacenan
solamente como SHA-256. El access token dura 15 minutos; el refresh token dura
30 días y la renovación lo rota. Cada cuenta mantiene como máximo cinco
sesiones activas.

Pendientes de despliegue: añadir limitación de tasa para login, registro,
verificación y renovación; usar un outbox transaccional para correo; decidir
una respuesta uniforme de registro que no permita enumerar cuentas; y evaluar
un lock por usuario en lugar del lock advisory global actual.
