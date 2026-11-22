# Perfil público y alias

Este cambio parte de la implementación del servidor de sesiones de #23 y añade
un perfil público independiente de la cuenta de correo y de cualquier nombre o
ID de entrenador.

## Persistencia

`server/db/20261120_25_public_profiles.sql` añade:

- `public_profiles`, una fila por cuenta con el alias mostrado, su forma
  normalizada y la fecha del último cambio;
- `public_alias_reservations`, que conserva cada alias liberado durante el
  periodo de reserva.

La unicidad case-insensitive se aplica mediante `alias_normalized` y la
restricción `UNIQUE`. El prefijo fechado evita colisiones con otras ramas. El
orden de aplicación combinado es `001_sessions.sql`,
`002_outbox_retry_state.sql`, `20261119_34_cloud_save_versions.sql` y después
`20261120_25_public_profiles.sql`; las migraciones de outbox y guardados se
conservan sin sustituir la del perfil. El servidor valida las tablas que
corresponden a cada subsistema al arrancar y permanece no disponible si falta
cualquiera de ellas.

## API

- `PUT /v1/profile` con `Authorization: Bearer <access-token>` y
  `{"alias":"..."}` crea o cambia el alias elegido por la cuenta.
- `GET /v1/profile` devuelve únicamente `alias`.

El servidor no genera un alias desde el correo o el entrenador. El alias
mostrado se guarda en forma canónica minúscula, después de quitar espacios
externos. Alias inválidos, reservados, duplicados, cambiados antes de 30 días
o recuperados durante la reserva de 90 días se rechazan con un conflicto o
error de validación explícito.

Al liberar un alias se actualiza su reserva con la fecha actual. Si una reserva
ya expiró y el alias se reutiliza, la reserva caducada se elimina; no se
mantiene una fecha histórica que extienda o acorte accidentalmente el nuevo
periodo. No se inventa aquí ningún flujo de borrado de cuenta: las reservas
huérfanas solo se conservan hasta que expire su plazo y su limpieza posterior
queda para una política de retención futura.

## Integración posterior con ranking

El ranking debe unir internamente `save_versions.user_id` con
`public_profiles.user_id`, usar únicamente `public_profiles.public_alias` y no
serializar `users.email`, credenciales, tokens, nombres de entrenador ni el
identificador de cuenta. La respuesta pública debe proyectar solo los campos
definidos por la especificación del leaderboard.
