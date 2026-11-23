#!/bin/bash
# Publica el frontend Angular en AWS con HTTPS. El Learner Lab no permite CloudFront, asi que el
# build se sube a un bucket S3 con website hosting y lo sirve el mismo API Gateway HTTP del BFF:
#
#   ANY /api/{proxy+}  -> BFF (Elastic IP :8081)
#   GET /              -> sitio S3 (index.html)
#   ANY /{proxy+}      -> sitio S3 (js, css, assets; las rutas de Angular caen en index.html)
#
# Frontend y API quedan en el mismo origen HTTPS (la URL del API Gateway), que es la redirect URI
# a registrar en Azure AD (plataforma "Single-page application"). Ademas agrega ese origen a
# ALLOWED_ORIGINS del BFF y al CORS del bucket de fotos (subida directa con URL prefirmada).
# Idempotente: se puede volver a correr para publicar una nueva version del frontend.
#
# Requisitos: Node.js 22 y los repos como carpetas hermanas. Uso: ./frontend.sh [--skip-build]
set -euo pipefail
export MSYS_NO_PATHCONV=1
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

SCRIPT_DIR=$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))
ROOT=${ANDESSTAY_ROOT:-$(cd "$SCRIPT_DIR/../.." && (pwd -W 2>/dev/null || pwd))}
FRONT="$ROOT/frontend-andesstay"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
WEB_BUCKET="andesstay-web-${ACCOUNT}"
IMAGES_BUCKET="andesstay-images-${ACCOUNT}"
WEBSITE="http://${WEB_BUCKET}.s3-website-${AWS_DEFAULT_REGION}.amazonaws.com"

API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='andesstay-api']|[0].ApiId" --output text)
[ "$API_ID" != "None" ] || { echo "No existe el API Gateway andesstay-api: correr primero ./provision.sh"; exit 1; }
ORIGIN=$(aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text)
EIP=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=andesstay-bff --query 'Addresses[0].PublicIp' --output text)
echo "Frontend -> ${ORIGIN}"

# --- 1. Build (environment.production.ts apunta al origen del API Gateway) --------------
ENV_FILE="$FRONT/src/environments/environment.production.ts"
if ! grep -q "const origin = '${ORIGIN}';" "$ENV_FILE"; then
  sed -i -E "s#^const origin = '[^']*';#const origin = '${ORIGIN}';#" "$ENV_FILE"
  echo "environment.production.ts actualizado a ${ORIGIN} (commitear el cambio)"
fi
if [ "${1:-}" != "--skip-build" ]; then
  [ -d "$FRONT/node_modules" ] || (cd "$FRONT" && npm ci)
  (cd "$FRONT" && npx ng build)
fi
DIST="$FRONT/dist/frontend-andesstay/browser"
grep -qF "$ORIGIN" "$DIST"/*.js ||{ echo "El build no apunta a ${ORIGIN}"; exit 1; }

# --- 2. Bucket S3 con website hosting y lectura publica --------------------------------
aws s3api head-bucket --bucket "$WEB_BUCKET" 2>/dev/null || aws s3api create-bucket --bucket "$WEB_BUCKET" >/dev/null
aws s3api put-public-access-block --bucket "$WEB_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
aws s3api put-bucket-policy --bucket "$WEB_BUCKET" --policy \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::${WEB_BUCKET}/*\"}]}"
# Error document = index.html: una ruta de Angular recargada (p.ej. /reservations/5) carga la SPA.
aws s3api put-bucket-website --bucket "$WEB_BUCKET" --website-configuration \
  '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}'

# js/css llevan hash en el nombre (cache larga); index.html nunca se cachea.
aws s3 sync --only-show-errors --delete "$DIST" "s3://$WEB_BUCKET" --exclude index.html --cache-control "public,max-age=86400"
aws s3 cp --only-show-errors "$DIST/index.html" "s3://$WEB_BUCKET/index.html" --cache-control "no-cache"
echo "Build subido a s3://${WEB_BUCKET}"

# --- 3. Rutas del API Gateway ----------------------------------------------------------
integration() {   # devuelve el id de la integracion HTTP_PROXY con esa URI (la crea si no existe)
  local uri=$1 id
  id=$(aws apigatewayv2 get-integrations --api-id "$API_ID" --query "Items[?IntegrationUri=='${uri}']|[0].IntegrationId" --output text)
  if [ "$id" = "None" ]; then
    id=$(aws apigatewayv2 create-integration --api-id "$API_ID" --integration-type HTTP_PROXY --integration-method ANY \
      --integration-uri "$uri" --payload-format-version 1.0 --query IntegrationId --output text)
  fi
  echo "$id"
}
route() {         # crea la ruta o la redirige a la integracion indicada
  local key=$1 int=$2 id
  id=$(aws apigatewayv2 get-routes --api-id "$API_ID" --query "Items[?RouteKey=='${key}']|[0].RouteId" --output text)
  if [ "$id" = "None" ]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$key" --target "integrations/$int" >/dev/null
  else
    aws apigatewayv2 update-route --api-id "$API_ID" --route-id "$id" --target "integrations/$int" >/dev/null
  fi
  echo "  ${key} -> integrations/${int}"
}
BFF_INT=$(integration "http://${EIP}:8081/api/{proxy}")
WEB_INT=$(integration "${WEBSITE}/{proxy}")
WEB_ROOT_INT=$(integration "${WEBSITE}/")
# S3 responde las rutas de Angular con index.html pero con 404: se reescribe a 200 (como el
# "custom error response" de CloudFront) para que el navegador las trate como paginas normales.
aws apigatewayv2 update-integration --api-id "$API_ID" --integration-id "$WEB_INT" \
  --response-parameters '{"404":{"overwrite:statuscode":"200"}}' >/dev/null
route 'ANY /api/{proxy+}' "$BFF_INT"     # primero la API, para no cortarla al mover el catch-all
route 'GET /' "$WEB_ROOT_INT"
route 'ANY /{proxy+}' "$WEB_INT"

# Integraciones que quedaron sin ruta (la anterior /{proxy} -> BFF).
USED=$(aws apigatewayv2 get-routes --api-id "$API_ID" --query 'Items[].Target' --output text)
for id in $(aws apigatewayv2 get-integrations --api-id "$API_ID" --query 'Items[].IntegrationId' --output text); do
  echo "$USED" | grep -q "integrations/${id}" || aws apigatewayv2 delete-integration --api-id "$API_ID" --integration-id "$id"
done

# --- 4. CORS: BFF y bucket de fotos aceptan el nuevo origen ----------------------------
ORIGINS="http://localhost:4200,${ORIGIN}"
aws s3api put-bucket-cors --bucket "$IMAGES_BUCKET" --cors-configuration \
  "{\"CORSRules\":[{\"AllowedOrigins\":[\"${ORIGINS//,/\",\"}\"],\"AllowedMethods\":[\"PUT\",\"GET\"],\"AllowedHeaders\":[\"*\"],\"MaxAgeSeconds\":3000}]}"

BFF_ID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=andesstay-bff Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$BFF_ID" = "None" ]; then
  echo "La EC2 del BFF no esta corriendo: ALLOWED_ORIGINS no se actualizo"
else
  cmd=$(aws ssm send-command --instance-ids "$BFF_ID" --document-name AWS-RunShellScript --parameters "{\"commands\":[
      \"grep -qx 'ALLOWED_ORIGINS=${ORIGINS}' /etc/andesstay.env && echo 'ALLOWED_ORIGINS sin cambios' && exit 0\",
      \"sed -i '/^ALLOWED_ORIGINS=/d' /etc/andesstay.env\",
      \"echo 'ALLOWED_ORIGINS=${ORIGINS}' >> /etc/andesstay.env\",
      \"systemctl restart andesstay\",
      \"for i in \$(seq 1 40); do curl -sf localhost:8081/actuator/health && exit 0; sleep 5; done; exit 1\"
    ]}" --query Command.CommandId --output text)
  aws ssm wait command-executed --command-id "$cmd" --instance-id "$BFF_ID" 2>/dev/null || true
  echo "BFF: $(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$BFF_ID" --query '[Status,StandardOutputContent]' --output text | tr '\n' ' ')"
fi

cat <<EOF

Listo: ${ORIGIN}
Registrar en Azure AD (App registrations -> AndesStay -> Authentication -> Single-page application):
  ${ORIGIN}
  ${ORIGIN}/login
EOF
