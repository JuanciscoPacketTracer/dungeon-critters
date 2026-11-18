# Dungeon Critters API

La API es la única frontera entre el cliente y PostgreSQL/Supabase. El juego no
debe usar credenciales de Supabase ni conectarse directamente a la base de datos.

La API requiere `DATABASE_URL`, `VERIFICATION_TOKEN_SECRETS` y
`VERIFICATION_TOKEN_KEY_VERSION`. El worker de outbox requerirá
`RESEND_API_KEY`, `RESEND_FROM_EMAIL` y `PUBLIC_API_URL`; `RESEND_FROM_EMAIL`
debe pertenecer a un dominio verificado.
En producción `PUBLIC_API_URL` debe ser una URL HTTPS absoluta sin credenciales.
Solo desarrollo permite omitirla y usa `http://localhost:9292`. Los secretos se
configuran fuera del repositorio y no se escriben en logs.

`VERIFICATION_TOKEN_SECRETS` es un objeto JSON versionado, por ejemplo
`{"v1":"secreto-largo"}`, y `VERIFICATION_TOKEN_KEY_VERSION` selecciona la
versión actual. El token enviado se deriva temporalmente con HMAC-SHA256 a
partir del usuario, un nonce, su expiración y esa versión; la base de datos solo
guarda el digest SHA-256 del token y los metadatos necesarios para regenerarlo.
Al rotar, se añade la nueva versión sin retirar la anterior hasta que caduquen
los mensajes pendientes; así no se invalidan enlaces vigentes.

Los tests sustituyen Resend por un doble; no se ha enviado correo real. La
configuración externa de PostgreSQL, Resend y el dominio debe verificarse antes
del despliegue.

`test/server_migration_test.rb` solo comprueba estáticamente que el SQL declara
creación idempotente y las columnas de tokens esperadas. No aplica la migración
ni demuestra compatibilidad con una instancia PostgreSQL real.

El PR #48 aún está abierto y no se encontró evidencia en este repositorio de
una base existente con el esquema anterior de `email_outbox`; por eso
`001_sessions.sql` es el esquema inicial único. Al arrancar, la API inspecciona
las columnas y falla explícitamente si encuentra la columna antigua `token` o
un esquema incompleto. No transforma ni elimina columnas automáticamente.
Antes de desplegar se debe aplicar `001_sessions.sql` sobre una base nueva o
detenerse y preparar una migración versionada revisada si el guard detecta una
base existente.

Rutas: `POST /v1/accounts`, `POST` o `GET /v1/accounts/verify-email`,
`POST /v1/sessions`, `POST /v1/sessions/refresh`,
`DELETE /v1/sessions/current` y `GET /v1/sessions/current`.

El enlace usa un fragmento `#token=...`, que nunca se envía al servidor. El
`GET` solo muestra una confirmación con JavaScript que lee el fragmento y ofrece
un `POST` explícito; no consume ni refleja el token en HTML. Esto evita que los
escáneres de correo verifiquen cuentas. La respuesta GET usa
`Cache-Control: no-store` y `Referrer-Policy: no-referrer`.

Argon2id usa formato PHC con `m=19456`, `t=2`, `p=1`. Los tokens de sesión se
almacenan solamente como SHA-256. El access token dura 15 minutos; el refresh
token dura 30 días y la renovación lo rota. Cada cuenta mantiene como máximo
cinco sesiones activas.

El registro responde siempre `{ "registration_received": true }` para cuentas
nuevas y existentes. La API solo persiste la cuenta y el outbox; no construye
`ResendMailer` ni envía correo. El worker debe construir `ResendMailer`, llamar
al dispatcher después del commit y liberar el lock global antes de llamar a
Resend. Un fallo deja el mensaje pendiente y no cambia la respuesta uniforme
del registro. Los leases expirados se pueden reclamar, pero se requiere un
worker de outbox autónomo con reintentos y observabilidad para producción; sin
ese worker la entrega no está garantizada.

Pendientes de despliegue: añadir limitación de tasa para login, registro,
verificación y renovación; implementar y operar un worker autónomo de outbox
con polling, backoff, límite de reintentos, observabilidad y recuperación de
leases; y evaluar un lock por usuario en lugar del lock advisory global actual.
Este PR no incluye un ejecutable del worker: hasta definir su scheduler,
credenciales y política operativa, la entrega de correo no está garantizada.
