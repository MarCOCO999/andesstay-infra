#!/usr/bin/env bash
# Crea los topicos del sistema AndesStay con su configuracion, o la ajusta si ya existen.
# Es idempotente: se puede ejecutar las veces que haga falta (kafka-init lo corre al levantar
# el cluster). Los mismos valores estan en el application.yml del microservicio duenio de
# cada topico (andesstay.kafka.topics), que los vuelve a aplicar al arrancar.
#
# Variables:
#   BOOTSTRAP           brokers (por defecto kafka-1:29092,kafka-2:29092,kafka-3:29092)
#   REPLICATION_FACTOR  replicas por particion (3; 1 para un cluster de un solo broker)
#   MIN_ISR             min.insync.replicas (2; nunca mayor que REPLICATION_FACTOR)
set -euo pipefail

BOOTSTRAP="${BOOTSTRAP:-kafka-1:29092,kafka-2:29092,kafka-3:29092}"
RF="${REPLICATION_FACTOR:-3}"
MIN_ISR="${MIN_ISR:-2}"
if (( MIN_ISR > RF )); then MIN_ISR="$RF"; fi

DAY_MS=86400000

# topic <nombre> <particiones> <config1=valor,config2=valor,...>
topic() {
  local name="$1" partitions="$2" configs="$3,min.insync.replicas=${MIN_ISR}"
  if kafka-topics --bootstrap-server "$BOOTSTRAP" --describe --topic "$name" >/dev/null 2>&1; then
    echo ">> $name ya existe: se aplica la configuracion"
    kafka-configs --bootstrap-server "$BOOTSTRAP" --alter --entity-type topics --entity-name "$name" --add-config "$configs"
  else
    echo ">> Creando $name (particiones=$partitions, replicas=$RF)"
    local args=()
    IFS=',' read -ra pairs <<< "$configs"
    for pair in "${pairs[@]}"; do args+=(--config "$pair"); done
    kafka-topics --bootstrap-server "$BOOTSTRAP" --create --if-not-exists --topic "$name" \
      --partitions "$partitions" --replication-factor "$RF" "${args[@]}"
  fi
}

echo "Esperando al cluster en $BOOTSTRAP..."
for _ in $(seq 1 30); do
  kafka-topics --bootstrap-server "$BOOTSTRAP" --list >/dev/null 2>&1 && break
  sleep 2
done

# reservations.events: fuente de verdad de los cambios de estado de cada reserva (productor:
# reservations; consumidores: audit y report). 3 particiones = paralelismo de 3 consumidores por
# grupo; key = reservationId para mantener el orden de los eventos de una misma reserva.
# Se conserva 7 dias (delete): suficiente para reprocesar si un consumidor estuvo caido.
topic reservations.events 3 "cleanup.policy=delete,retention.ms=$((7 * DAY_MS)),max.message.bytes=1048576"

# audit.timeline: ultimo estado conocido de cada reserva (productor: audit; consumidor: report).
# Compactado por reservationId: un consumidor nuevo reconstruye el estado actual leyendo desde
# el inicio sin recorrer todo el historial. Segmentos de 1 hora para que la compactacion corra
# seguido; las tombstones (valor null) se conservan 1 dia antes de eliminarse.
topic audit.timeline 3 "cleanup.policy=compact,segment.ms=3600000,min.compaction.lag.ms=60000,delete.retention.ms=${DAY_MS},min.cleanable.dirty.ratio=0.1"

# Dead-letter topics: mensajes que agotaron sus reintentos. Bajo volumen (1 particion, orden
# de llegada para investigar) y retencion mas larga (14 dias) para dar tiempo a revisarlos.
topic reservations.events.DLT 1 "cleanup.policy=delete,retention.ms=$((14 * DAY_MS))"
topic audit.timeline.DLT 1 "cleanup.policy=delete,retention.ms=$((14 * DAY_MS))"

echo
kafka-topics --bootstrap-server "$BOOTSTRAP" --describe --topics-with-overrides
echo "Topicos listos."
