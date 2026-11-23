#!/bin/bash
# Se ejecuta EN la EC2 de infraestructura (desde infra-user-data.sh al crearla, o via SSM con
# rabbit-cluster.sh): levanta el cluster RabbitMQ de 2 nodos + rabbitmq-init con el mismo
# infra/mq/compose.yml que se usa en local. Es idempotente.
set -euxo pipefail

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="andesstay-deploy-${ACCOUNT}"
DIR=/opt/andesstay/mq

mkdir -p "$DIR"
aws s3 cp --only-show-errors "s3://${BUCKET}/infra/mq/compose.yml" "$DIR/compose.yml"

# Migracion desde la version anterior (un solo nodo dentro del compose principal, junto a Oracle):
# se quita ese servicio del compose principal y su contenedor. Las colas se vuelven a declarar
# solas: los microservicios las crean al reconectarse.
if [ -f /opt/andesstay/compose.yml ] && grep -q '^  rabbitmq:' /opt/andesstay/compose.yml; then
  sed -i '/^  rabbitmq:/,/^volumes:/{/^volumes:/!d}' /opt/andesstay/compose.yml
  sed -i '/^  rabbitmq-data:/d' /opt/andesstay/compose.yml
fi
if docker inspect andesstay-rabbitmq >/dev/null 2>&1 \
   && [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' andesstay-rabbitmq)" != "andesstay-mq" ]; then
  docker rm -f andesstay-rabbitmq
fi

RABBITMQ_USERNAME=andesstay RABBITMQ_PASSWORD=changeit docker compose -f "$DIR/compose.yml" up -d --remove-orphans

# rabbitmq-init verifica que ambos nodos esten en el cluster, aplica la politica y termina.
docker wait andesstay-rabbitmq-init
docker logs andesstay-rabbitmq-init 2>&1 | tail -10
docker ps --format '{{.Names}}\t{{.Status}}' | grep rabbitmq
