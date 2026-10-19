#!/bin/bash
# Lanza una EC2 t3.small por microservicio (7: bff, reservations, catalog, audit, report,
# rabbit-admin, notify). Cada instancia descarga su jar desde el bucket
# de despliegue (usando el rol LabInstanceProfile, sin claves embebidas) y lo corre como
# servicio systemd con Corretto 21. El orden importa: reservations necesita la IP privada
# de catalog, y el BFF las de todos los servicios de dominio.
#
# Uso: INFRA_IP=<ip privada infra> APP_SG=<sg> SUBNET=<subnet> ./deploy-apps.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="andesstay-deploy-${ACCOUNT}"
IMAGES_BUCKET="andesstay-images-${ACCOUNT}"
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
declare -A PORT=([bff]=8081 [reservations]=8082 [catalog]=8083 [audit]=8084 [report]=8085 [rabbit-admin]=8086 [notify]=8090)
declare -A IP

launch() {
  local svc=$1 extra_env=$2
  local existing
  existing=$(aws ec2 describe-instances \
    --filters Name=tag:Name,Values="andesstay-${svc}" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[0].Instances[0].[InstanceId,PrivateIpAddress]' --output text)
  if [ "$(echo "$existing" | awk '{print $1}')" != "None" ]; then
    IP[$svc]=$(echo "$existing" | awk '{print $2}')
    echo "${svc} ya existe: ${existing}"
    if [ -n "$extra_env" ]; then
      sync_env "$svc" "$(echo "$existing" | awk '{print $1}')" "$extra_env"
    fi
    return 0
  fi

  local user_data
  user_data=$(cat <<EOF
#!/bin/bash
set -euxo pipefail
dnf install -y java-21-amazon-corretto-headless
mkdir -p /opt/andesstay
aws s3 cp s3://${DEPLOY_BUCKET}/jars/ms-andesstay-${svc}.jar /opt/andesstay/app.jar
cat > /etc/andesstay.env <<ENV
SERVER_PORT=${PORT[$svc]}
DB_URL=jdbc:oracle:thin:@${INFRA_IP}:1521/FREEPDB1
DB_USERNAME=andesstay
DB_PASSWORD=changeit
KAFKA_BOOTSTRAP_SERVERS=${INFRA_IP}:9092
RABBITMQ_HOST=${INFRA_IP}
RABBITMQ_USERNAME=andesstay
RABBITMQ_PASSWORD=changeit
AWS_REGION=us-east-1
S3_IMAGES_BUCKET=${IMAGES_BUCKET}
${extra_env}
ENV
cat > /etc/systemd/system/andesstay.service <<UNIT
[Unit]
Description=ms-andesstay-${svc}
After=network-online.target
[Service]
EnvironmentFile=/etc/andesstay.env
ExecStart=/usr/bin/java -Xms256m -Xmx768m -jar /opt/andesstay/app.jar
Restart=always
RestartSec=15
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now andesstay
EOF
)
  local out
  out=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.small --key-name vockey \
    --security-group-ids "$APP_SG" --subnet-id "$SUBNET" \
    --iam-instance-profile Name=LabInstanceProfile \
    --user-data "$user_data" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=andesstay-${svc}},{Key=Project,Value=andesstay}]" \
    --query 'Instances[0].[InstanceId,PrivateIpAddress]' --output text)
  IP[$svc]=$(echo "$out" | awk '{print $2}')
  echo "${svc} ${out}"
}

# Una instancia que ya existia puede tener variables desactualizadas (p.ej. el BFF antes de
# que existiera rabbit-admin): se reescriben esas lineas de /etc/andesstay.env via SSM y se
# reinicia el servicio. Requiere que la instancia este encendida.
sync_env() {
  local svc=$1 id=$2 extra_env=$3
  local commands="" line key
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key=${line%%=*}
    commands+="\"sed -i '/^${key}=/d' /etc/andesstay.env\",\"echo '${line}' >> /etc/andesstay.env\","
  done <<< "$extra_env"
  commands+="\"systemctl restart andesstay\""
  local cmd
  cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "{\"commands\":[${commands}]}" --query Command.CommandId --output text)
  aws ssm wait command-executed --command-id "$cmd" --instance-id "$id" 2>/dev/null || true
  echo "${svc}: variables actualizadas ($(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
    --query Status --output text))"
}

launch catalog ""
launch notify ""
launch audit ""
launch report ""
launch rabbit-admin ""
launch reservations "CATALOG_SERVICE_URL=http://${IP[catalog]}:8083"
launch bff "ALLOWED_ORIGINS=${ALLOWED_ORIGINS:-http://localhost:4200}
RESERVATIONS_SERVICE_URL=http://${IP[reservations]}:8082
CATALOG_SERVICE_URL=http://${IP[catalog]}:8083
AUDIT_SERVICE_URL=http://${IP[audit]}:8084
REPORT_SERVICE_URL=http://${IP[report]}:8085
RABBIT_ADMIN_SERVICE_URL=http://${IP[rabbit-admin]}:8086"
