#!/bin/bash
# Crea desde cero todo el despliegue de AndesStay en una cuenta de AWS (Learner Lab):
# security groups, buckets S3, EC2 de infraestructura, una EC2 por microservicio, Elastic IP
# para el BFF y el API Gateway HTTP. Si un recurso ya existe (por nombre/tag) lo reutiliza,
# asi que se puede volver a correr sin duplicar nada.
#
# Requisitos: AWS CLI con credenciales del lab, Java 21+ (para compilar los jars) y los repos
# ms-andesstay-* clonados como carpetas hermanas de este repo. En Windows, correrlo desde Git Bash.
#
# Uso: ./provision.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1   # evita que Git Bash reescriba rutas como /aws/service/... o /{proxy}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

# pwd -W da rutas C:/... en Git Bash (aws.exe no entiende /c/...); en Linux/Mac cae a pwd.
SCRIPT_DIR=$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))
ROOT=${ANDESSTAY_ROOT:-$(cd "$SCRIPT_DIR/../.." && (pwd -W 2>/dev/null || pwd))}
SERVICES=(bff reservations catalog audit report rabbit-admin notify)
ALLOWED_ORIGINS=${ALLOWED_ORIGINS:-http://localhost:4200}

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="andesstay-deploy-${ACCOUNT}"
IMAGES_BUCKET="andesstay-images-${ACCOUNT}"
echo "Cuenta ${ACCOUNT} / region ${AWS_DEFAULT_REGION}"

VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=availability-zone,Values="${AWS_DEFAULT_REGION}a" \
  --query 'Subnets[0].SubnetId' --output text)
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

# --- Security groups --------------------------------------------------------------------
sg_id() {
  aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values="$1" \
    --query 'SecurityGroups[0].GroupId' --output text
}

APP_SG=$(sg_id andesstay-app)
if [ "$APP_SG" = "None" ]; then
  APP_SG=$(aws ec2 create-security-group --group-name andesstay-app --description "AndesStay microservicios" \
    --vpc-id "$VPC" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$APP_SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=tcp,FromPort=8081,ToPort=8081,IpRanges=[{CidrIp=0.0.0.0/0,Description=API Gateway hacia BFF}]" \
    "IpProtocol=tcp,FromPort=8082,ToPort=8090,UserIdGroupPairs=[{GroupId=$APP_SG}]" >/dev/null
fi

INFRA_SG=$(sg_id andesstay-infra)
if [ "$INFRA_SG" = "None" ]; then
  INFRA_SG=$(aws ec2 create-security-group --group-name andesstay-infra --description "AndesStay Oracle RabbitMQ Kafka" \
    --vpc-id "$VPC" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$INFRA_SG" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    "IpProtocol=tcp,FromPort=1521,ToPort=1521,UserIdGroupPairs=[{GroupId=$APP_SG}]" \
    "IpProtocol=tcp,FromPort=5672,ToPort=5672,UserIdGroupPairs=[{GroupId=$APP_SG}]" \
    "IpProtocol=tcp,FromPort=9092,ToPort=9092,UserIdGroupPairs=[{GroupId=$APP_SG}]" \
    "IpProtocol=tcp,FromPort=15672,ToPort=15672,IpRanges=[{CidrIp=0.0.0.0/0,Description=RabbitMQ UI}]" \
    "IpProtocol=tcp,FromPort=8089,ToPort=8089,IpRanges=[{CidrIp=0.0.0.0/0,Description=Kafka UI}]" >/dev/null
fi
echo "Security groups: app=${APP_SG} infra=${INFRA_SG}"

# --- Buckets S3 -------------------------------------------------------------------------
for b in "$DEPLOY_BUCKET" "$IMAGES_BUCKET"; do
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || aws s3api create-bucket --bucket "$b" >/dev/null
done
# Fotos de las unidades: subida directa desde el navegador (URL prefirmada) y lectura publica
# solo bajo units/, que es donde ms-andesstay-catalog guarda las imagenes.
aws s3api put-bucket-cors --bucket "$IMAGES_BUCKET" --cors-configuration \
  "{\"CORSRules\":[{\"AllowedOrigins\":[\"${ALLOWED_ORIGINS//,/\",\"}\"],\"AllowedMethods\":[\"PUT\",\"GET\"],\"AllowedHeaders\":[\"*\"],\"MaxAgeSeconds\":3000}]}"
aws s3api put-public-access-block --bucket "$IMAGES_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
aws s3api put-bucket-policy --bucket "$IMAGES_BUCKET" --policy \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PublicReadUnits\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::${IMAGES_BUCKET}/units/*\"}]}"
echo "Buckets: ${DEPLOY_BUCKET} ${IMAGES_BUCKET}"

# --- Jars -------------------------------------------------------------------------------
for svc in "${SERVICES[@]}"; do
  dir="$ROOT/ms-andesstay-$svc"
  (cd "$dir" && env -u MSYS_NO_PATHCONV ./mvnw -q -DskipTests clean package)
  aws s3 cp --only-show-errors "$dir/target/ms-andesstay-$svc-0.0.1-SNAPSHOT.jar" "s3://$DEPLOY_BUCKET/jars/ms-andesstay-$svc.jar"
  echo "jar ${svc} subido"
done
aws s3 cp --only-show-errors "$ROOT/infra/db/seed-catalog.sql" "s3://$DEPLOY_BUCKET/sql/seed-catalog.sql"

# --- EC2 --------------------------------------------------------------------------------
instance_id() {
  aws ec2 describe-instances --filters Name=tag:Name,Values="$1" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

INFRA_ID=$(instance_id andesstay-infra)
if [ "$INFRA_ID" = "None" ]; then
  INFRA_ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.large --key-name vockey \
    --security-group-ids "$INFRA_SG" --subnet-id "$SUBNET" \
    --iam-instance-profile Name=LabInstanceProfile \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3}' \
    --user-data "file://$SCRIPT_DIR/infra-user-data.sh" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=andesstay-infra},{Key=Project,Value=andesstay}]' \
    --query 'Instances[0].InstanceId' --output text)
fi
INFRA_IP=$(aws ec2 describe-instances --instance-ids "$INFRA_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "EC2 infra ${INFRA_ID} (${INFRA_IP})"

# Lanza solo las EC2 de aplicacion que falten; las existentes se reutilizan (para actualizar
# el codigo de un servicio que ya corre: ./redeploy.sh <servicio>).
INFRA_IP=$INFRA_IP APP_SG=$APP_SG SUBNET=$SUBNET ALLOWED_ORIGINS=$ALLOWED_ORIGINS bash "$SCRIPT_DIR/deploy-apps.sh"
BFF_ID=$(instance_id andesstay-bff)

# --- Elastic IP del BFF (la IP publica no cambia al detener/encender el lab) ------------
aws ec2 wait instance-running --instance-ids "$BFF_ID"
EIP=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=andesstay-bff --query 'Addresses[0].PublicIp' --output text)
if [ "$EIP" = "None" ]; then
  ALLOC=$(aws ec2 allocate-address --domain vpc \
    --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=andesstay-bff}]' --query AllocationId --output text)
  EIP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC" --query 'Addresses[0].PublicIp' --output text)
else
  ALLOC=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=andesstay-bff --query 'Addresses[0].AllocationId' --output text)
fi
aws ec2 associate-address --instance-id "$BFF_ID" --allocation-id "$ALLOC" >/dev/null
echo "BFF ${BFF_ID} (${EIP})"

# --- API Gateway HTTP ------------------------------------------------------------------
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='andesstay-api']|[0].ApiId" --output text)
if [ "$API_ID" = "None" ]; then
  API_ID=$(aws apigatewayv2 create-api --name andesstay-api --protocol-type HTTP --query ApiId --output text)
  INT_ID=$(aws apigatewayv2 create-integration --api-id "$API_ID" --integration-type HTTP_PROXY --integration-method ANY \
    --integration-uri "http://${EIP}:8081/{proxy}" --payload-format-version 1.0 --query IntegrationId --output text)
  aws apigatewayv2 create-route --api-id "$API_ID" --route-key 'ANY /{proxy+}' --target "integrations/$INT_ID" >/dev/null
  aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null
else
  INT_ID=$(aws apigatewayv2 get-integrations --api-id "$API_ID" --query 'Items[0].IntegrationId' --output text)
  aws apigatewayv2 update-integration --api-id "$API_ID" --integration-id "$INT_ID" \
    --integration-uri "http://${EIP}:8081/{proxy}" >/dev/null
fi
API_URL=$(aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text)

INFRA_PUBLIC=$(aws ec2 describe-instances --instance-ids "$INFRA_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
cat <<EOF

Listo. Los servicios tardan unos minutos en arrancar la primera vez.
  API Gateway : ${API_URL}   (poner esta URL en frontend-andesstay/src/environments/environment.aws.ts)
  RabbitMQ UI : http://${INFRA_PUBLIC}:15672  (andesstay / changeit)
  Kafka UI    : http://${INFRA_PUBLIC}:8089
Datos de ejemplo del catalogo (una vez que catalog haya arrancado):  ./seed.sh
EOF
