#!/bin/bash
# Agrega un JWT Authorizer (Microsoft Entra ID) al API Gateway: las rutas /api/** solo llegan al
# BFF con un access token valido (firma, issuer, audience y vigencia); si no, el gateway responde
# 401 sin tocar el backend. El BFF sigue validando el token y ademas aplica los roles por ruta.
#
#   ANY     /api/{proxy+}  -> JWT authorizer -> BFF
#   OPTIONS /api/{proxy+}  -> sin authorizer -> BFF   (preflight CORS de localhost:4200, nunca trae token)
#   GET / y ANY /{proxy+}  -> sin authorizer -> frontend en S3 (ver frontend.sh)
#
# Idempotente. Uso: ./api-jwt.sh   (TENANT_ID / API_CLIENT_ID se pueden sobreescribir por env)
set -euo pipefail
export MSYS_NO_PATHCONV=1
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

TENANT_ID=${TENANT_ID:-fbf645d5-8f6d-45fc-9e8d-c8866d008af1}
API_CLIENT_ID=${API_CLIENT_ID:-d6959b0c-9ec2-432e-bddb-54bd0e83ace9}
ISSUER="https://login.microsoftonline.com/${TENANT_ID}/v2.0"
# Mismo criterio que el AudienceValidator del BFF: Entra ID v2 emite el "aud" como GUID o como api://GUID.
AUDIENCES="${API_CLIENT_ID},api://${API_CLIENT_ID}"
NAME=andesstay-entra-jwt

API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='andesstay-api']|[0].ApiId" --output text)
[ "$API_ID" != "None" ] || { echo "No existe el API Gateway andesstay-api: correr primero ./provision.sh"; exit 1; }

API_ROUTE=$(aws apigatewayv2 get-routes --api-id "$API_ID" --query "Items[?RouteKey=='ANY /api/{proxy+}']|[0].[RouteId,Target]" --output text)
[ "$(echo "$API_ROUTE" | awk '{print $1}')" != "None" ] || { echo "Falta la ruta ANY /api/{proxy+}: correr primero ./frontend.sh"; exit 1; }
API_ROUTE_ID=$(echo "$API_ROUTE" | awk '{print $1}')
BFF_TARGET=$(echo "$API_ROUTE" | awk '{print $2}')

AUTH_ID=$(aws apigatewayv2 get-authorizers --api-id "$API_ID" --query "Items[?Name=='${NAME}']|[0].AuthorizerId" --output text)
JWT_CONFIG="Issuer=${ISSUER},Audience=${AUDIENCES}"
if [ "$AUTH_ID" = "None" ]; then
  AUTH_ID=$(aws apigatewayv2 create-authorizer --api-id "$API_ID" --name "$NAME" --authorizer-type JWT \
    --identity-source '$request.header.Authorization' --jwt-configuration "$JWT_CONFIG" --query AuthorizerId --output text)
else
  aws apigatewayv2 update-authorizer --api-id "$API_ID" --authorizer-id "$AUTH_ID" \
    --identity-source '$request.header.Authorization' --jwt-configuration "$JWT_CONFIG" >/dev/null
fi
echo "Authorizer ${NAME} (${AUTH_ID}): issuer ${ISSUER}, audience ${AUDIENCES}"

# Primero la ruta OPTIONS (sin authorizer), luego se protege la ruta ANY.
OPT_ID=$(aws apigatewayv2 get-routes --api-id "$API_ID" --query "Items[?RouteKey=='OPTIONS /api/{proxy+}']|[0].RouteId" --output text)
if [ "$OPT_ID" = "None" ]; then
  aws apigatewayv2 create-route --api-id "$API_ID" --route-key 'OPTIONS /api/{proxy+}' --target "$BFF_TARGET" >/dev/null
else
  aws apigatewayv2 update-route --api-id "$API_ID" --route-id "$OPT_ID" --target "$BFF_TARGET" --authorization-type NONE >/dev/null
fi
aws apigatewayv2 update-route --api-id "$API_ID" --route-id "$API_ROUTE_ID" \
  --authorization-type JWT --authorizer-id "$AUTH_ID" >/dev/null

aws apigatewayv2 get-routes --api-id "$API_ID" --query 'Items[].[RouteKey,AuthorizationType]' --output text | sort
