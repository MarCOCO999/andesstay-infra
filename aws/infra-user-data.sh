#!/bin/bash
# User-data de la EC2 de infraestructura (Amazon Linux 2023): instala Docker y levanta
# Oracle Free y RabbitMQ con la misma configuracion que los compose de db/ y mq/, y el cluster
# Kafka (3 Zookeeper + 3 brokers + Kafka UI) con el mismo kafka/compose.yml que en local, via
# kafka-cluster-ec2.sh (provision.sh lo sube antes al bucket de despliegue). La unica
# diferencia es el listener anunciado de Kafka, que usa la IP privada de esta instancia para
# que las EC2 de aplicacion puedan conectarse.
set -euxo pipefail

dnf install -y docker
systemctl enable --now docker
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

mkdir -p /opt/andesstay
cat > /opt/andesstay/compose.yml <<EOF
name: andesstay
services:
  oracle:
    image: gvenzl/oracle-free:23-slim
    container_name: andesstay-oracle
    restart: unless-stopped
    ports: ["1521:1521"]
    environment:
      ORACLE_PASSWORD: changeit
      APP_USER: andesstay
      APP_USER_PASSWORD: changeit
    volumes: [oracle-data:/opt/oracle/oradata]

  rabbitmq:
    image: rabbitmq:3.13-management
    container_name: andesstay-rabbitmq
    hostname: andesstay-rabbitmq
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: andesstay
      RABBITMQ_DEFAULT_PASS: changeit
    ports: ["5672:5672", "15672:15672"]
    volumes: [rabbitmq-data:/var/lib/rabbitmq]

volumes:
  oracle-data:
  rabbitmq-data:
EOF

docker compose -f /opt/andesstay/compose.yml up -d

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws s3 cp "s3://andesstay-deploy-${ACCOUNT}/infra/kafka-cluster-ec2.sh" /opt/andesstay/kafka-cluster-ec2.sh
bash /opt/andesstay/kafka-cluster-ec2.sh
