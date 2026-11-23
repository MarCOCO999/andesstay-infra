#!/bin/bash
# Se ejecuta EN la EC2 de infraestructura (desde infra-user-data.sh al crearla, o via SSM con
# kafka-cluster.sh): levanta el cluster Kafka de 3 Zookeeper + 3 brokers + kafka-init + Kafka UI
# con el mismo infra/kafka/compose.yml que se usa en local, anunciando la IP privada de la
# instancia para que las EC2 de aplicacion puedan conectarse. Es idempotente.
set -euxo pipefail

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="andesstay-deploy-${ACCOUNT}"
DIR=/opt/andesstay/kafka

mkdir -p "$DIR"
aws s3 cp --only-show-errors --recursive "s3://${BUCKET}/infra/kafka" "$DIR"

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

# Migracion desde la version anterior (1 Zookeeper + 1 broker dentro del compose principal):
# se quitan esos servicios del compose principal y sus contenedores. Los datos del broker
# anterior se pierden, pero todo lo consumido ya esta persistido en Oracle por audit y report.
if [ -f /opt/andesstay/compose.yml ] && grep -q '^  zookeeper:' /opt/andesstay/compose.yml; then
  sed -i '/^  zookeeper:/,/^volumes:/{/^volumes:/!d}' /opt/andesstay/compose.yml
fi
docker rm -f andesstay-zookeeper andesstay-kafka 2>/dev/null || true
if docker inspect andesstay-kafka-ui >/dev/null 2>&1 \
   && [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' andesstay-kafka-ui)" != "andesstay-kafka" ]; then
  docker rm -f andesstay-kafka-ui
fi

KAFKA_ADVERTISED_HOST="$PRIVATE_IP" docker compose -f "$DIR/compose.yml" up -d --remove-orphans

# kafka-init crea/ajusta los topicos y termina; se espera su resultado.
docker wait andesstay-kafka-init
docker logs andesstay-kafka-init 2>&1 | grep -v WARNING | tail -12
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'kafka|zookeeper'
