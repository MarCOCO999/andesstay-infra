#!/bin/bash
# Compila uno o mas microservicios, sube el jar al bucket de despliegue y reinicia el
# servicio en su EC2 via SSM (no hace falta SSH ni la llave del lab).
#
# Uso: ./redeploy.sh catalog [reservations ...]
set -euo pipefail
export MSYS_NO_PATHCONV=1
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

[ $# -gt 0 ] || { echo "Uso: $0 <bff|reservations|catalog|audit|report|rabbit-admin|notify> ..."; exit 1; }

# pwd -W da rutas C:/... en Git Bash (aws.exe no entiende /c/...); en Linux/Mac cae a pwd.
SCRIPT_DIR=$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))
ROOT=${ANDESSTAY_ROOT:-$(cd "$SCRIPT_DIR/../.." && (pwd -W 2>/dev/null || pwd))}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="andesstay-deploy-${ACCOUNT}"
declare -A PORT=([bff]=8081 [reservations]=8082 [catalog]=8083 [audit]=8084 [report]=8085 [rabbit-admin]=8086 [notify]=8090)

for svc in "$@"; do
  [ -n "${PORT[$svc]:-}" ] || { echo "Servicio desconocido: $svc"; exit 1; }
  dir="$ROOT/ms-andesstay-$svc"

  echo "[$svc] compilando..."
  (cd "$dir" && env -u MSYS_NO_PATHCONV ./mvnw -q -DskipTests clean package)
  aws s3 cp --only-show-errors "$dir/target/ms-andesstay-$svc-0.0.1-SNAPSHOT.jar" "s3://$DEPLOY_BUCKET/jars/ms-andesstay-$svc.jar"

  id=$(aws ec2 describe-instances --filters Name=tag:Name,Values="andesstay-$svc" Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  [ "$id" != "None" ] || { echo "[$svc] no hay una EC2 andesstay-$svc corriendo"; exit 1; }

  echo "[$svc] reiniciando en ${id}..."
  cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "{\"commands\":[
      \"aws s3 cp --only-show-errors s3://$DEPLOY_BUCKET/jars/ms-andesstay-$svc.jar /opt/andesstay/app.jar\",
      \"systemctl restart andesstay\",
      \"for i in \$(seq 1 40); do curl -sf localhost:${PORT[$svc]}/actuator/health && exit 0; sleep 5; done; journalctl -u andesstay -n 30 --no-pager; exit 1\"
    ]}" --query Command.CommandId --output text)
  aws ssm wait command-executed --command-id "$cmd" --instance-id "$id" 2>/dev/null || true
  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
    --query '[Status,StandardOutputContent]' --output text | tail -5
done
