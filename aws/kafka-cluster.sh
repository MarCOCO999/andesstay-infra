#!/bin/bash
# Sube infra/kafka (compose.yml + scripts) al bucket de despliegue y (re)levanta el cluster Kafka
# de 3 Zookeeper + 3 brokers en la EC2 de infraestructura via SSM (ejecuta kafka-cluster-ec2.sh
# alla). Sirve para aplicar cambios del compose o de los topicos, y para migrar una EC2 creada
# con la version anterior de un solo broker. Con --upload-only solo sube los archivos (lo usa
# provision.sh antes de crear la EC2, cuyo user-data los descarga).
#
# Uso: ./kafka-cluster.sh [--upload-only]
set -euo pipefail
export MSYS_NO_PATHCONV=1
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

SCRIPT_DIR=$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))
ROOT=${ANDESSTAY_ROOT:-$(cd "$SCRIPT_DIR/../.." && (pwd -W 2>/dev/null || pwd))}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="andesstay-deploy-${ACCOUNT}"

aws s3 cp --only-show-errors "$ROOT/infra/kafka/compose.yml" "s3://$DEPLOY_BUCKET/infra/kafka/compose.yml"
aws s3 cp --only-show-errors --recursive "$ROOT/infra/kafka/scripts" "s3://$DEPLOY_BUCKET/infra/kafka/scripts"
aws s3 cp --only-show-errors "$SCRIPT_DIR/kafka-cluster-ec2.sh" "s3://$DEPLOY_BUCKET/infra/kafka-cluster-ec2.sh"
echo "infra/kafka subido a s3://$DEPLOY_BUCKET/infra/"
[ "${1:-}" = "--upload-only" ] && exit 0

id=$(aws ec2 describe-instances --filters Name=tag:Name,Values=andesstay-infra Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$id" != "None" ] || { echo "No hay una EC2 andesstay-infra corriendo"; exit 1; }

echo "Levantando el cluster en ${id} (la primera vez descarga las imagenes, puede tardar unos minutos)..."
cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript --timeout-seconds 1200 \
  --parameters "{\"executionTimeout\":[\"1200\"],\"commands\":[
    \"aws s3 cp --only-show-errors s3://$DEPLOY_BUCKET/infra/kafka-cluster-ec2.sh /opt/andesstay/kafka-cluster-ec2.sh\",
    \"bash /opt/andesstay/kafka-cluster-ec2.sh\"
  ]}" --query Command.CommandId --output text)

status=InProgress
while [ "$status" = "InProgress" ] || [ "$status" = "Pending" ] || [ "$status" = "Delayed" ]; do
  sleep 10
  status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
done
aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query StandardOutputContent --output text | tail -25
echo "Estado: $status"
[ "$status" = "Success" ]
