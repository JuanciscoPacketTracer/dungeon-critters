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
`ResendMailer` ni envía correo. El worker construye `ResendMailer`, llama al
dispatcher después del commit y libera el lock global antes de llamar a Resend.
Un fallo deja el mensaje pendiente y no cambia la respuesta uniforme del
registro. Los leases expirados se pueden reclamar.

El worker ejecutable es `bundle exec ruby server/bin/outbox_worker.rb`. Requiere
`DATABASE_URL`, `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, `PUBLIC_API_URL` (HTTPS en
producción), `VERIFICATION_TOKEN_SECRETS` y
`VERIFICATION_TOKEN_KEY_VERSION`. No usa la URL localhost ni el secreto de
desarrollo como fallback: si falta cualquiera de estas variables, el proceso
termina antes de reclamar un mensaje. Consulta el outbox cada
`OUTBOX_POLL_INTERVAL` segundos (5 por defecto), intenta entregar cada mensaje
hasta `OUTBOX_MAX_ATTEMPTS` veces en total (5 por defecto), usa backoff
exponencial limitado por `OUTBOX_BACKOFF_MAX` (60 segundos por defecto) y
recupera leases vencidos.
`OUTBOX_BACKOFF_BASE` controla el primer retraso (1 segundo por defecto).
`SIGINT` y `SIGTERM` detienen el polling ordenadamente. Los logs solo incluyen
contadores y clases de error; nunca mensajes de error, tokens ni secretos.
Cada intento incrementa `attempts` antes de llamar a Resend. `claim_token` identifica al dueño de cada lease; las confirmaciones y
transiciones de fallo solo aplican si ese token sigue siendo el actual.
`next_attempt_at`
persiste el backoff y `terminal_at` marca un fallo permanente cuando se alcanza
el límite; por eso un reinicio no reinicia el contador ni reintenta antes de
tiempo. Una señal recibida durante la espera evita iniciar otro intento.

Para una base creada con la versión anterior de `001_sessions.sql`, aplicar
explícitamente `server/db/002_outbox_retry_state.sql` antes de iniciar el
worker. La aplicación no añade columnas ni transforma mensajes automáticamente;
el guard de arranque rechaza esquemas incompletos.

Si Resend acepta un envío pero el worker pierde la conexión antes de persistir
`sent_at`, el resultado es incierto: el lease queda para recuperación y otro
worker puede reenviar el mismo mensaje. Por ello la entrega es al menos una vez
y pueden existir duplicados; Resend debe tratarse como un destino idempotente
cuando sea posible. Un fallo de PostgreSQL al guardar el backoff o el estado
terminal se registra explícitamente y conserva el lease para que la recuperación
no pierda el intento.

Pendientes de despliegue: añadir limitación de tasa para login, registro,
verificación y renovación; operar el worker con un scheduler/servicio
supervisado, credenciales y alertas; y evaluar un lock por usuario en lugar del
lock advisory global actual. La entrega es al menos una vez: un lease que expire
durante una llamada lenta puede producir un envío duplicado. Un mensaje en estado
terminal requiere intervención operativa (corregir la causa y reencolarlo de
forma explícita); no se promete entrega exactamente una vez.
