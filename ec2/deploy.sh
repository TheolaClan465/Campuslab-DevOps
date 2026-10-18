#!/usr/bin/env bash
# Conserva el Compose, el .env y los wallets existentes en EC2.
set -euo pipefail

DEPLOY_DIR=${1:?Falta directorio}
SERVICE=${2:?Falta servicio}
REGISTRY=${3:?Falta registro}
IMAGE=${4:?Falta imagen con SHA}
case "$SERVICE" in
  bff) PORT=8080 ;;
  catalog) PORT=8081 ;;
  booking) PORT=8082 ;;
  notify) PORT= ;;
  *) echo 'Servicio no permitido'; exit 1 ;;
esac
[[ "$REGISTRY" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || exit 1
[[ "$IMAGE" =~ ^[a-z0-9./-]+:[a-f0-9]{40}$ ]] || exit 1
[[ "$IMAGE" == "$REGISTRY/"* ]] || exit 1
cd "$DEPLOY_DIR"

# Evita que dos servicios modifiquen el mismo proyecto a la vez.
exec 9>.campuslab-deploy.lock
flock -w 300 9
BASE_FILES=()
if [[ -n "${COMPOSE_FILE:-}" ]]; then
  IFS=: read -ra FILES <<< "$COMPOSE_FILE"
  for FILE in "${FILES[@]}"; do BASE_FILES+=(-f "$FILE"); done
else
  for FILE in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [[ -f "$FILE" ]]; then BASE_FILES=(-f "$FILE"); break; fi
  done
  for FILE in compose.override.yaml compose.override.yml docker-compose.override.yaml docker-compose.override.yml; do
    if [[ -f "$FILE" ]]; then BASE_FILES+=(-f "$FILE"); break; fi
  done
fi
[[ ${#BASE_FILES[@]} -gt 0 ]] || { echo 'No se encontró el Compose'; exit 1; }
compose() { sudo -n env ECR_REGISTRY="$REGISTRY" docker compose "${BASE_FILES[@]}" "$@"; }
compose config --services | grep -Fx -- "$SERVICE" >/dev/null

# Descarga antes de reemplazar. No elimina el contenedor manualmente.
sudo -n docker pull "$IMAGE"
EXPECTED_IMAGE=$(sudo -n docker image inspect --format '{{.Id}}' "$IMAGE")
# Notify necesita el broker y el SMTP de prueba de este mismo Compose.
if [[ "$SERVICE" == notify ]]; then
  compose up -d --wait --wait-timeout 180 rabbitmq mailpit
fi
# Usa el commit exacto aunque otro workflow cambie latest.
OVERRIDE=$(mktemp "$DEPLOY_DIR/.deploy-image.XXXXXX.yml")
trap 'rm -f "$OVERRIDE"' EXIT
printf 'services:\n  %s:\n    image: %s\n' "$SERVICE" "$IMAGE" > "$OVERRIDE"
compose -f "$OVERRIDE" up -d --no-deps --force-recreate "$SERVICE"
CID=$(compose -f "$OVERRIDE" ps -aq "$SERVICE")
[[ -n "$CID" ]] || { echo 'No se creó el contenedor'; exit 1; }

# Up no basta: Spring debe completar el arranque y escuchar en su puerto.
for ATTEMPT in $(seq 1 36); do
  STATUS=$(sudo -n docker inspect --format '{{.State.Status}} {{.RestartCount}} {{.Image}}' "$CID")
  read -r STATE RESTARTS ACTUAL_IMAGE <<< "$STATUS"
  if [[ "$STATE" != running || "$RESTARTS" != 0 || "$ACTUAL_IMAGE" != "$EXPECTED_IMAGE" ]]; then
    echo "Arranque fallido: $STATUS"
    sudo -n docker logs --tail 80 "$CID"
    exit 1
  fi
  READY_PATTERN='Started .*Application'
  if [[ "$SERVICE" == notify ]]; then READY_PATTERN='NOTIFY_CLOUD_READY:'; fi
  if sudo -n docker logs "$CID" 2>&1 | grep "$READY_PATTERN" >/dev/null; then
    if [[ -z "$PORT" ]] || sudo -n docker exec "$CID" bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT"; then
      echo "Despliegue verificado: $SERVICE ($IMAGE)"; exit 0
    fi
  fi
  sleep 5
done
echo 'Tiempo agotado esperando el arranque; no se hizo rollback automático.'
sudo -n docker logs --tail 80 "$CID"
exit 1
