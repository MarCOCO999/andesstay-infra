# andesstay-infra

Infraestructura compartida del proyecto **AndesStay** (caso DSY1107 – Desarrollo Cloud Native I, Duoc UC): los `docker-compose` que levantan Oracle, RabbitMQ y Kafka+Zookeeper para desarrollo local, y las notas de cómo se replica lo mismo en AWS.

## Contenido

| Carpeta | Qué levanta | Puertos |
|---|---|---|
| `db/` | Oracle Database Free 23ai (imagen `gvenzl/oracle-free:23-slim`), con el PDB `FREEPDB1` y un usuario de aplicación ya creados | `1521` |
| `mq/` | Clúster RabbitMQ de 2 nodos con plugin de management, más `rabbitmq-init`, que aplica la política de réplica de colas. Ver [Clúster RabbitMQ](#clúster-rabbitmq) | `5672`/`5673` (AMQP), `15672`/`15673` (UI) |
| `kafka/` | Clúster Kafka: 3 nodos Zookeeper + 3 brokers (sin KRaft, tal como pide el caso), creación de los tópicos del sistema (`kafka-init`) y Kafka UI. Ver [Diseño de Kafka](#diseño-de-kafka) | `2181`–`2183`, `9092`–`9094`, `8089` (UI) |

Cada carpeta es independiente: se pueden levantar todas juntas o solo las que se necesiten para trabajar en un microservicio puntual.

| Otras carpetas | Contenido |
|---|---|
| `aws/` | Scripts de despliegue en el Learner Lab (ver [Despliegue en AWS](#despliegue-en-aws-aws-academy-learner-lab)) |
| `db/seed-catalog.sql` | Unidades de ejemplo para el catálogo |
| `docs/` | **[Matriz de funcionalidades](docs/matriz-funcionalidades.md)**: alcance completo del proyecto con estado, componente responsable y evidencia de cada funcionalidad |

## Preparar un computador nuevo

| Herramienta | Para qué | Versión |
|---|---|---|
| Git | Clonar los repos | cualquiera |
| Docker Desktop (abierto antes de levantar la infraestructura) | Oracle, RabbitMQ y Kafka en local | 4.x |
| Java (JDK) | Compilar y correr los microservicios | 21 o superior |
| Node.js + npm | Frontend Angular | Node 22 |
| AWS CLI v2 | Solo para desplegar o administrar AWS | 2.x |

**Hardware:** se recomiendan **16 GB de RAM** en el equipo. Oracle, el clúster Kafka (~3,5 GB), RabbitMQ y los 8 microservicios juntos ocupan bastante memoria (en Windows, Docker Desktop corre sobre WSL2 y toma la RAM que necesita del total del equipo).

**Puertos que deben estar libres:** `1521`, `5672`–`5673`, `15672`–`15673`, `2181`–`2183`, `9092`–`9094`, `8089` (infraestructura), `8081`–`8087`, `8090` (microservicios) y `4200` (frontend).

### Clonar los repos

Los 9 repos tienen que quedar como **carpetas hermanas** dentro de una misma carpeta, y el de infraestructura con el nombre `infra` (los scripts de `aws/` buscan `../ms-andesstay-*` e `infra/db/`). Se clona la rama **`main`**, que es la que tiene el código al día.

PowerShell:

```powershell
mkdir AndesStay; cd AndesStay
$repos = "andesstay-infra", "frontend-andesstay", "ms-andesstay-bff", "ms-andesstay-reservations",
         "ms-andesstay-catalog", "ms-andesstay-notify", "ms-andesstay-audit", "ms-andesstay-report",
         "ms-andesstay-rabbit-admin"
foreach ($r in $repos) { git clone -b main "https://github.com/MarCOCO999/$r.git" }
Rename-Item andesstay-infra infra
```

Git Bash / Linux / Mac:

```bash
mkdir AndesStay && cd AndesStay
for r in andesstay-infra frontend-andesstay ms-andesstay-bff ms-andesstay-reservations ms-andesstay-catalog \
         ms-andesstay-notify ms-andesstay-audit ms-andesstay-report ms-andesstay-rabbit-admin; do
  git clone -b main https://github.com/MarCOCO999/$r.git
done
mv andesstay-infra infra
```

Maven no hace falta instalarlo: cada microservicio trae su wrapper (`mvnw` / `mvnw.cmd`). La primera compilación descarga las dependencias, así que requiere internet.

### Cuenta de Azure AD

El login (MSAL) funciona desde cualquier computador porque la redirección es a `http://localhost:4200`, pero la cuenta con la que se ingresa tiene que pertenecer al tenant del caso **y tener asignado un App Role** (`Admin`, `Operador`, `Cliente` o `Auditor`) en la aplicación registrada. Sin rol, el login funciona pero la API responde `403`.

## Cómo levantar todo en local

No requiere ninguna credencial de AWS. Comandos para PowerShell, desde la carpeta `AndesStay`:

**1. Infraestructura** (Docker Desktop abierto). Oracle tarda 1–3 minutos en quedar `(healthy)` en `docker ps`. El compose de Kafka espera a que los 3 brokers estén sanos, crea los tópicos (`andesstay-kafka-init` termina con `Topicos listos.` en su log) y levanta Kafka UI.

```powershell
docker compose -f infra\db\compose.yml up -d
docker compose -f infra\mq\compose.yml up -d
docker compose -f infra\kafka\compose.yml up -d
```

**2. Microservicios**, cada uno en su propia terminal. `catalog` debe arrancar antes que `reservations`, y el BFF al final:

```powershell
cd ms-andesstay-catalog;      .\mvnw.cmd spring-boot:run   # 8083
cd ms-andesstay-reservations; .\mvnw.cmd spring-boot:run   # 8082
cd ms-andesstay-notify;       .\mvnw.cmd spring-boot:run   # 8090
cd ms-andesstay-audit;        .\mvnw.cmd spring-boot:run   # 8084
cd ms-andesstay-report;       .\mvnw.cmd spring-boot:run   # 8085
cd ms-andesstay-rabbit-admin; .\mvnw.cmd spring-boot:run   # 8086
cd ms-andesstay-kafka-admin;  .\mvnw.cmd spring-boot:run   # 8087
cd ms-andesstay-bff;          .\mvnw.cmd spring-boot:run   # 8081
```

Cada uno responde `"status":"UP"` en `http://localhost:<puerto>/actuator/health`.

**3. Datos de ejemplo** (la base parte vacía; correr una vez que `catalog` haya arrancado, porque es Hibernate quien crea las tablas):

```powershell
Get-Content infra\db\seed-catalog.sql | docker exec -i andesstay-oracle sqlplus -s andesstay/changeit@FREEPDB1
```

**4. Frontend** en http://localhost:4200 (`npm ci` solo la primera vez):

```powershell
cd frontend-andesstay; npm ci
npx ng serve          # contra el backend local (localhost:8081)
npx ng serve -c aws   # contra el API Gateway de AWS (environment.aws.ts)
```

| UI local | URL | Credenciales |
|---|---|---|
| Frontend | http://localhost:4200 | cuenta de Azure AD del caso |
| RabbitMQ (nodo 1 / nodo 2) | http://localhost:15672 / http://localhost:15673 | `guest` / `guest` |
| Kafka UI | http://localhost:8089 | — |

Credenciales por defecto (solo para desarrollo local, nunca usar en un ambiente real): Oracle `andesstay` / `changeit`, RabbitMQ `guest` / `guest`.

**Subida de fotos en local:** es lo único que depende de AWS. `catalog` firma la URL de subida con las credenciales de AWS del computador y contra el bucket de `S3_IMAGES_BUCKET`, así que para probarla hay que tener credenciales del lab vigentes y arrancar catalog con `$env:S3_IMAGES_BUCKET="andesstay-images-<account-id>"`. Todo lo demás funciona sin AWS.

Para apagar: `Ctrl+C` en cada microservicio y `docker compose -f infra\<db|mq|kafka>\compose.yml down` (con `-v` se borran también los datos).

## Clúster RabbitMQ

RabbitMQ transporta los **comandos** hacia `ms-andesstay-notify`: 3 colas (`q.cmd.email`, `q.cmd.housekeeping` y `q.cmd.voucher`), cada una con su cola de reintento (`.retry`) y su DLQ (`.dlq`). Los exchanges son `cmd.direct` (direct), `cmd.topic` (topic), `cmd.retry` y `cmd.dead.dlx` (dead-letter).

- **2 nodos** (`rabbit@andesstay-rabbitmq` y `rabbit@andesstay-rabbitmq-2`) que comparten la Erlang cookie. El clúster se forma solo con *peer discovery* `classic_config`: el nodo 2 arranca cuando el nodo 1 está sano y se une. Exchanges, colas, usuarios y políticas pertenecen al clúster y se administran desde cualquiera de los dos nodos.
- **Réplica de colas:** `rabbitmq-init` aplica la política `ha-all` (`^q\.` → `ha-mode: all`, sincronización automática). Cada cola tiene un líder en un nodo y una réplica en el otro. Si cae un nodo, la réplica asume y las colas siguen atendiendo sin perder los mensajes ya encolados.
- **Clientes:** reservations, notify y rabbit-admin reciben ambas direcciones (`SPRING_RABBITMQ_ADDRESSES=<ip>:5672,<ip>:5673`) y se reconectan solos al nodo que siga vivo.
- **Por qué colas clásicas replicadas y no *quorum queues*:** una quorum queue necesita mayoría (2 de 2 con dos nodos), así que no toleraría la caída de ninguno. Con 2 nodos, la réplica clásica es la opción que sí da tolerancia a fallos. Con un tercer nodo, lo recomendado sería migrar a quorum queues, porque la réplica clásica está deprecada desde RabbitMQ 3.13.

## Diseño de Kafka

Kafka transporta los **eventos** del dominio (algo que ya ocurrió y que varios servicios quieren conocer, cada uno a su ritmo); RabbitMQ sigue a cargo de los **comandos** hacia `ms-andesstay-notify` (una tarea para un único destinatario, con reintento y DLQ por cola). Kafka se agregó sin tocar las integraciones de RabbitMQ: `ms-andesstay-reservations` publica en ambos desde clases separadas (`messaging/kafka` y `messaging/rabbit`).

### Clúster

3 nodos Zookeeper (quórum de 2) y 3 brokers. Los tópicos del sistema usan **factor de replicación 3** y **`min.insync.replicas` 2**, y los productores escriben con `acks=all` e idempotencia: una escritura se confirma cuando al menos 2 réplicas la tienen, así que el clúster sigue aceptando escrituras y lecturas con un broker caído sin perder eventos confirmados. La creación automática de tópicos está desactivada: cada tópico se crea de forma explícita con su configuración.

### Tópicos

| Tópico | Productor | Consumidores (consumer group) | Particiones | Limpieza / retención | Por qué |
|---|---|---|---|---|---|
| `reservations.events` | reservations | audit (`ms-andesstay-audit`), report (`ms-andesstay-report`) | 3 | `delete`, 7 días | Fuente de verdad de los cambios de estado. Key = `reservationId`: los eventos de una reserva van a la misma partición y se procesan en orden. 7 días alcanzan para que un consumidor caído se ponga al día. |
| `audit.timeline` | audit | report (`ms-andesstay-report-snapshots`) | 3 | `compact` (segmentos de 1 h, tombstones 1 día) | Último estado auditado de cada reserva. Al ser compactado por `reservationId`, un consumidor nuevo reconstruye el estado actual de todas las reservas sin recorrer el historial completo (que ya está en Oracle). |
| `reservations.events.DLT` | audit, report | monitor de audit (`ms-andesstay-audit-dlt-monitor`) | 1 | `delete`, 14 días | Eventos que no se pudieron procesar. Bajo volumen (1 partición, orden de llegada) y retención mayor para investigarlos y reprocesarlos. |
| `audit.timeline.DLT` | report | monitor de report (`ms-andesstay-report-dlt-monitor`) | 1 | `delete`, 14 días | Ídem para el timeline. |

La configuración está en tres lugares coherentes entre sí: el `application.yml` del servicio **dueño** (productor) de cada tópico (`andesstay.kafka.topics`, que Spring aplica al arrancar), `kafka/scripts/create-topics.sh` (lo corre `kafka-init` al levantar el clúster) y, para cambios en caliente, `ms-andesstay-kafka-admin`.

### Consumer groups

- **Pub/sub entre servicios:** audit y report usan grupos distintos sobre `reservations.events`, así que **cada uno recibe todos los eventos** y avanza a su propio ritmo; si report se cae, audit no se atrasa.
- **Balanceo dentro de un servicio:** cada listener corre con 3 hilos (1 por partición). Si se levanta otra instancia del mismo servicio, comparte el grupo y Kafka reparte las particiones entre ambas (rebalanceo cooperativo: solo se mueven las particiones necesarias).
- **Un grupo por flujo:** report consume `reservations.events` y `audit.timeline` con grupos distintos, de modo que cada flujo confirma sus offsets por separado y el snapshot se puede reconstruir reseteando solo su grupo.
- **Monitores de DLT** en grupos propios, para que leer los DLT no compita con el procesamiento normal.

### Administración

| Herramienta | Para qué |
|---|---|
| `ms-andesstay-kafka-admin` (`/api/kafka/**`, rol Admin) | Clúster, tópicos (crear, configurar, aumentar particiones, eliminar) y consumer groups (lag, reset de offsets, eliminar), con protección de los tópicos y grupos del sistema |
| Kafka UI (`:8089`) | Inspección visual de brokers, tópicos, mensajes y consumer groups |
| `kafka/scripts/kafka-ops.sh` | Las mismas operaciones por consola (`topics`, `describe`, `set-config`, `partitions`, `groups`, `group`, `reset`, `peek`) |
| `kafka/scripts/create-topics.sh` | Crea o reajusta los tópicos del sistema; idempotente (`docker compose -f infra/kafka/compose.yml run --rm kafka-init`) |

## Despliegue en AWS (AWS Academy Learner Lab)

Para la entrega del caso, esta misma infraestructura corre en una **EC2 de infraestructura** (Oracle + RabbitMQ + el clúster Kafka de 3 brokers vía Docker, la misma configuración que estos `compose.yml`), separada de las EC2 de aplicación (una por microservicio: BFF, reservations, catalog, notify, audit, report, rabbit-admin, kafka-admin). Un **API Gateway** HTTP API queda al frente del BFF como única puerta de entrada pública.

```
Navegador → API Gateway HTTP ─ /api/** → BFF (EC2 + Elastic IP :8081) → reservations | catalog | audit | report | rabbit-admin | kafka-admin
                          └─ resto ──→ S3 andesstay-web (frontend Angular)
                                                                                    │
          EC2 infra: Oracle :1521 · RabbitMQ :5672-5673 (2 nodos) · Kafka :9092-9094 (3 brokers) ◄──┘ (+ notify)
```

### Credenciales del lab

En el Learner Lab: **AWS Details → AWS CLI → Show**, y copiar el bloque completo en `~/.aws/credentials` bajo `[default]`. `aws configure` por sí solo **no alcanza**: no pide el `aws_session_token`, que es obligatorio en el lab (se puede agregar con `aws configure set aws_session_token <token>`). Región: `aws configure set region us-east-1`. Las credenciales vencen al terminar cada sesión del lab y hay que repetir este paso.

```bash
aws sts get-caller-identity   # debe mostrar el rol voclabs
```

### Scripts (`aws/`)

Se corren con **bash** (en Windows, desde Git Bash). Todos usan el rol `LabInstanceProfile` en las EC2, así que ninguna clave de AWS queda en el código ni en las instancias.

| Script | Qué hace |
|---|---|
| `provision.sh` | Crea todo desde cero: security groups, buckets S3 (jars y fotos, con CORS y lectura pública solo de `units/*`), EC2 de infraestructura, una EC2 por microservicio, Elastic IP del BFF y API Gateway. Compila y sube los jars. Si un recurso ya existe lo reutiliza, así que se puede volver a correr. Al terminar imprime la URL del API Gateway. |
| `redeploy.sh <servicio> ...` | Compila el/los microservicio(s), sube el jar y lo reinicia en su EC2 vía SSM. Ej: `./redeploy.sh catalog reservations` |
| `seed.sh` | Carga las unidades de ejemplo en el Oracle de AWS (idempotente). |
| `rabbit-cluster.sh` | Sube `mq/compose.yml` al bucket y (re)levanta el clúster RabbitMQ de 2 nodos en la EC2 de infraestructura vía SSM (con `rabbit-cluster-ec2.sh`), con el mismo compose que en local. Después configura reservations, notify y rabbit-admin con ambas direcciones (`SPRING_RABBITMQ_ADDRESSES`). También migra una EC2 creada con la versión anterior de un solo nodo. |
| `kafka-cluster.sh` | Sube `kafka/` (compose y scripts) al bucket y (re)levanta el clúster Kafka de 3 brokers en la EC2 de infraestructura vía SSM, con el mismo `kafka/compose.yml` que en local. También migra una EC2 creada con la versión anterior de un solo broker. |
| `infra-user-data.sh` | User-data de la EC2 de infraestructura (lo usa `provision.sh`); el clúster Kafka lo levanta con `kafka-cluster-ec2.sh`. |
| `api-jwt.sh` | Agrega al API Gateway un **JWT Authorizer** de Microsoft Entra ID: `/api/**` solo llega al BFF con un access token válido (firma, issuer, audience y vigencia), y si no, el gateway responde `401` sin tocar el backend. `OPTIONS /api/**` queda libre para los preflight CORS. |
| `frontend.sh` | Compila el frontend (`ng build`), lo sube a un bucket S3 con website hosting y lo publica en el **mismo API Gateway** (`/api/**` → BFF, el resto → S3), con HTTPS. CloudFront no está disponible en el Learner Lab. También agrega ese origen al CORS del BFF y del bucket de fotos. Se vuelve a correr para publicar una versión nueva del frontend. |
| `deploy-apps.sh` | Lanza las 8 EC2 de aplicación que falten y actualiza la configuración de las que ya existen (lo usa `provision.sh`). |

**Despliegue desde cero** (lab nuevo o cuenta distinta):

```bash
cd infra/aws
./provision.sh
./seed.sh        # unos minutos después, cuando catalog ya arrancó
./frontend.sh    # frontend en S3 detrás del API Gateway (requiere Node.js 22)
./api-jwt.sh     # JWT Authorizer de Entra ID en /api/**
```

Después, registrar la URL del API Gateway que imprime, más `<URL>/login`, como redirect URI de la plataforma **Single-page application** en la app registration de Azure AD. El frontend queda en esa URL, sin instalar nada en el computador que lo usa.

Para desarrollar el frontend en local contra el backend de AWS, poner la misma URL en `frontend-andesstay/src/environments/environment.aws.ts` y correr `npx ng serve -c aws` (http://localhost:4200).

**Sesiones siguientes del mismo lab:** no hay que desplegar nada. Al iniciar el lab las EC2 se encienden solas, y cada servicio arranca por sí mismo (systemd en las EC2 de aplicación, `restart: unless-stopped` en los contenedores). Las IP privadas no cambian y el BFF tiene Elastic IP, así que el API Gateway sigue funcionando. Lo único que cambia es la IP pública de la EC2 de infraestructura (UIs de RabbitMQ `:15672` y `:15673`, usuario `andesstay` / `changeit`, y Kafka `:8089`):

```bash
aws ec2 describe-instances --filters Name=tag:Name,Values=andesstay-infra \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

Se optó por Oracle **auto-gestionado con Docker en EC2** en vez de Amazon RDS for Oracle: RDS for Oracle requiere licencia (BYOL o License Included) y no aplica a los créditos de un Learner Lab, mientras que reutilizar el mismo contenedor que ya se usa en local no tiene costo de licencia y mantiene el mismo comportamiento entre desarrollo y despliegue.

Las imágenes de referencia de las unidades del catálogo se almacenan en **Amazon S3** (con subida directa desde el navegador vía URL prefirmada, ver [ms-andesstay-catalog](https://github.com/MarCOCO999/ms-andesstay-catalog)) en vez de un servicio externo como Cloudinary, para no introducir un proveedor adicional fuera del ecosistema AWS que ya usa el resto del caso.

## Repos relacionados

[frontend-andesstay](https://github.com/MarCOCO999/frontend-andesstay) · [ms-andesstay-bff](https://github.com/MarCOCO999/ms-andesstay-bff) · [ms-andesstay-reservations](https://github.com/MarCOCO999/ms-andesstay-reservations) · [ms-andesstay-catalog](https://github.com/MarCOCO999/ms-andesstay-catalog) · [ms-andesstay-notify](https://github.com/MarCOCO999/ms-andesstay-notify) · [ms-andesstay-audit](https://github.com/MarCOCO999/ms-andesstay-audit) · [ms-andesstay-report](https://github.com/MarCOCO999/ms-andesstay-report) · [ms-andesstay-rabbit-admin](https://github.com/MarCOCO999/ms-andesstay-rabbit-admin) · [ms-andesstay-kafka-admin](https://github.com/MarCOCO999/ms-andesstay-kafka-admin)
