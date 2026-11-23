#!/bin/bash
# Sube infra/mq/compose.yml al bucket de despliegue y (re)levanta el cluster RabbitMQ de 2 nodos
# en la EC2 de infraestructura via SSM (ejecuta rabbit-cluster-ec2.sh alla). Migra tambien una
# EC2 creada con la version anterior de un solo nodo. Con --upload-only solo sube los archivos
# (lo usa provision.sh antes de crear la EC2, cuyo user-data los descarga).
#
# Despues de migrar una EC2 existente, los microservicios que usan RabbitMQ deben recibir ambas
# direcciones: lo hace este mismo script (SPRING_RABBITMQ_ADDRESSES + reinicio).
#
# Uso: ./rabbit-cluster.sh [--upload-only]
set -euo pipefail
export MSYS_NO_PATHCONV=1
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

SCRIPT_DIR=$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))
ROOT=${ANDESSTAY_ROOT:-$(cd "$SCRIPT_DIR/../.." && (pwd -W 2>/dev/null || pwd))}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="andesstay-deploy-${ACCOUNT}"

aws s3 cp --only-show-errors "$ROOT/infra/mq/compose.yml" "s3://$DEPLOY_BUCKET/infra/mq/compose.yml"
aws s3 cp --only-show-errors "$SCRIPT_DIR/rabbit-cluster-ec2.sh" "s3://$DEPLOY_BUCKET/infra/rabbit-cluster-ec2.sh"
echo "infra/mq subido a s3://$DEPLOY_BUCKET/infra/"
[ "${1:-}" = "--upload-only" ] && exit 0

read -r id infra_ip < <(aws ec2 describe-instances --filters Name=tag:Name,Values=andesstay-infra Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].[InstanceId,PrivateIpAddress]' --output text | tr -d '\r')
[ "$id" != "None" ] || { echo "No hay una EC2 andesstay-infra corriendo"; exit 1; }

run_ssm() {   # run_ssm <instance-id> <json commands array> -> espera e imprime la salida
  local cmd status
  cmd=$(aws ssm send-command --instance-ids "$1" --document-name AWS-RunShellScript --timeout-seconds 900 \
    --parameters "{\"executionTimeout\":[\"900\"],\"commands\":$2}" --query Command.CommandId --output text)
  status=Pending
  while [ "$status" = "InProgress" ] || [ "$status" = "Pending" ] || [ "$status" = "Delayed" ]; do
    sleep 10
    status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$1" --query Status --output text 2>/dev/null || echo Pending)
  done
  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$1" --query StandardOutputContent --output text | tail -15
  [ "$status" = "Success" ]
}

echo "Levantando el cluster RabbitMQ en ${id}..."
run_ssm "$id" "[\"aws s3 cp --only-show-errors s3://$DEPLOY_BUCKET/infra/rabbit-cluster-ec2.sh /opt/andesstay/rabbit-cluster-ec2.sh\",\"bash /opt/andesstay/rabbit-cluster-ec2.sh\"]"

# Microservicios que usan RabbitMQ: ambas direcciones, para reconectarse al nodo que siga vivo.
ADDRESSES="SPRING_RABBITMQ_ADDRESSES=${infra_ip}:5672,${infra_ip}:5673"
for svc in reservations notify rabbit-admin; do
  sid=$(aws ec2 describe-instances --filters Name=tag:Name,Values="andesstay-$svc" Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  [ "$sid" != "None" ] || { echo "[$svc] no esta corriendo, se omite"; continue; }
  echo "[$svc] ${ADDRESSES}"
  run_ssm "$sid" "[\"sed -i '/^SPRING_RABBITMQ_ADDRESSES=/d' /etc/andesstay.env\",\"echo '${ADDRESSES}' >> /etc/andesstay.env\",\"systemctl restart andesstay\",\"for i in \$(seq 1 40); do curl -sf localhost:\$(grep ^SERVER_PORT= /etc/andesstay.env | cut -d= -f2)/actuator/health && exit 0; sleep 5; done; exit 1\"]"
done
