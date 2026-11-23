#!/usr/bin/env bash
# Operaciones de administracion del cluster Kafka local, ejecutadas con las herramientas de
# linea de comandos de un broker (docker exec). Es la alternativa por consola a
# ms-andesstay-kafka-admin y a Kafka UI.
#
#   ./kafka-ops.sh topics                          lista los topicos
#   ./kafka-ops.sh describe <topico>               particiones, lider, replicas, ISR y configuracion
#   ./kafka-ops.sh set-config <topico> k=v[,k=v]   modifica la configuracion (p.ej. retention.ms=86400000)
#   ./kafka-ops.sh partitions <topico> <n>         aumenta las particiones a n
#   ./kafka-ops.sh groups                          lista los consumer groups
#   ./kafka-ops.sh group <grupo>                   miembros, offsets y lag por particion
#   ./kafka-ops.sh reset <grupo> <topico> <--to-earliest|--to-latest|--to-datetime AAAA-MM-DDTHH:mm:SS.000>
#                                                  reubica los offsets (el grupo debe estar sin consumidores)
#   ./kafka-ops.sh peek <topico> [n]               muestra los primeros n mensajes (por defecto 10) con key, particion y offset
set -euo pipefail

BROKER="${KAFKA_CONTAINER:-andesstay-kafka-1}"
BOOTSTRAP="kafka-1:29092,kafka-2:29092,kafka-3:29092"
run() { docker exec -i "$BROKER" "$@"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  topics)     run kafka-topics --bootstrap-server "$BOOTSTRAP" --list ;;
  describe)   run kafka-topics --bootstrap-server "$BOOTSTRAP" --describe --topic "$1"
              run kafka-configs --bootstrap-server "$BOOTSTRAP" --describe --entity-type topics --entity-name "$1" ;;
  set-config) run kafka-configs --bootstrap-server "$BOOTSTRAP" --alter --entity-type topics --entity-name "$1" --add-config "$2" ;;
  partitions) run kafka-topics --bootstrap-server "$BOOTSTRAP" --alter --topic "$1" --partitions "$2" ;;
  groups)     run kafka-consumer-groups --bootstrap-server "$BOOTSTRAP" --list --state ;;
  group)      run kafka-consumer-groups --bootstrap-server "$BOOTSTRAP" --describe --group "$1" --members --verbose
              run kafka-consumer-groups --bootstrap-server "$BOOTSTRAP" --describe --group "$1" ;;
  reset)      group="$1"; topic="$2"; shift 2
              run kafka-consumer-groups --bootstrap-server "$BOOTSTRAP" --group "$group" --topic "$topic" \
                --reset-offsets "$@" --execute ;;
  peek)       n="${2:-10}"
              run kafka-console-consumer --bootstrap-server "$BOOTSTRAP" --topic "$1" --from-beginning \
                --max-messages "$n" --timeout-ms 5000 --property print.key=true --property print.partition=true \
                --property print.offset=true 2>&1 | grep -v -E "TimeoutException|Error processing message|^WARN" || true ;;
  *)          sed -n '2,17p' "$0"; exit 1 ;;
esac
