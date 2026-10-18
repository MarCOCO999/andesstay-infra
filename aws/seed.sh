#!/bin/bash
# Carga las unidades de ejemplo (db/seed-catalog.sql) en el Oracle de la EC2 de
# infraestructura via SSM. Es idempotente: las unidades que ya existen no se duplican.
#
# Uso: ./seed.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

# pwd -W da rutas C:/... en Git Bash (aws.exe no entiende /c/...); en Linux/Mac cae a pwd.
SCRIPT_DIR=$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="andesstay-deploy-${ACCOUNT}"

aws s3 cp --only-show-errors "$SCRIPT_DIR/../db/seed-catalog.sql" "s3://$DEPLOY_BUCKET/sql/seed-catalog.sql"
id=$(aws ec2 describe-instances --filters Name=tag:Name,Values=andesstay-infra Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
  --parameters "{\"commands\":[
    \"aws s3 cp --only-show-errors s3://$DEPLOY_BUCKET/sql/seed-catalog.sql /tmp/seed-catalog.sql\",
    \"docker exec -i andesstay-oracle sqlplus -s andesstay/changeit@FREEPDB1 < /tmp/seed-catalog.sql\"
  ]}" --query Command.CommandId --output text)
aws ssm wait command-executed --command-id "$cmd" --instance-id "$id" 2>/dev/null || true
aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
