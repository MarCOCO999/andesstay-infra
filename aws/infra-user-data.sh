#!/bin/bash
# User-data de la EC2 de infraestructura (Amazon Linux 2023): instala Docker y levanta
# Oracle Free, RabbitMQ y Zookeeper + Kafka con la misma configuracion que los compose
# de db/, mq/ y kafka/. La unica diferencia es el listener anunciado de Kafka, que usa la
# IP privada de esta instancia para que las EC2 de aplicacion puedan conectarse.
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

  zookeeper:
    image: confluentinc/cp-zookeeper:7.6.1
    container_name: andesstay-zookeeper
    restart: unless-stopped
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000

  kafka:
    image: confluentinc/cp-kafka:7.6.1
    container_name: andesstay-kafka
    restart: unless-stopped
    depends_on: [zookeeper]
    ports: ["9092:9092"]
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:29092,PLAINTEXT_HOST://${PRIVATE_IP}:9092
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:29092,PLAINTEXT_HOST://0.0.0.0:9092
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"

  kafka-ui:
    image: provectuslabs/kafka-ui:v0.7.2
    container_name: andesstay-kafka-ui
    restart: unless-stopped
    depends_on: [kafka]
    ports: ["8089:8080"]
    environment:
      KAFKA_CLUSTERS_0_NAME: andesstay
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: kafka:29092
      KAFKA_CLUSTERS_0_ZOOKEEPER: zookeeper:2181

volumes:
  oracle-data:
  rabbitmq-data:
EOF

docker compose -f /opt/andesstay/compose.yml up -d
