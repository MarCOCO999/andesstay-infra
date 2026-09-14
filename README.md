# andesstay-infra

Infraestructura compartida del proyecto **AndesStay** (caso DSY1107 – Desarrollo Cloud Native I, Duoc UC): los `docker-compose` que levantan Oracle, RabbitMQ y Kafka+Zookeeper para desarrollo local, y las notas de cómo se replica lo mismo en AWS.

## Contenido

| Carpeta | Qué levanta | Puertos |
|---|---|---|
| `db/` | Oracle Database Free 23ai (imagen `gvenzl/oracle-free:23-slim`), con el PDB `FREEPDB1` y un usuario de aplicación ya creados | `1521` |
| `mq/` | RabbitMQ de un solo nodo con plugin de management | `5672` (AMQP), `15672` (UI) |
| `kafka/` | Zookeeper + 1 broker Kafka (sin KRaft, tal como pide el caso) + Kafka UI | `2181`, `9092`, `8089` (UI) |

Cada carpeta es independiente: se pueden levantar todas juntas o solo las que se necesiten para trabajar en un microservicio puntual.

## Cómo levantar todo en local

Requiere Docker Desktop.

```bash
docker compose -f db/compose.yml up -d
docker compose -f mq/compose.yml up -d
docker compose -f kafka/compose.yml up -d
```

Credenciales por defecto (solo para desarrollo local, nunca usar en un ambiente real): Oracle `andesstay` / `changeit`, RabbitMQ `guest` / `guest`.

## Despliegue en AWS (AWS Academy Learner Lab)

Para la entrega del caso, esta misma infraestructura corre en una **EC2 de infraestructura** (Oracle + RabbitMQ + Kafka/Zookeeper vía Docker, la misma configuración que estos `compose.yml`), separada de las EC2 de aplicación (una por microservicio: BFF, reservations, catalog, notify, audit, report). Un **API Gateway** HTTP API queda al frente del BFF como única puerta de entrada pública.

Se optó por Oracle **auto-gestionado con Docker en EC2** en vez de Amazon RDS for Oracle: RDS for Oracle requiere licencia (BYOL o License Included) y no aplica a los créditos de un Learner Lab, mientras que reutilizar el mismo contenedor que ya se usa en local no tiene costo de licencia y mantiene el mismo comportamiento entre desarrollo y despliegue.

Las imágenes de referencia de las unidades del catálogo se almacenan en **Amazon S3** (con subida directa desde el navegador vía URL prefirmada, ver [ms-andesstay-catalog](https://github.com/MarCOCO999/ms-andesstay-catalog)) en vez de un servicio externo como Cloudinary, para no introducir un proveedor adicional fuera del ecosistema AWS que ya usa el resto del caso.

## Repos relacionados

[frontend-andesstay](https://github.com/MarCOCO999/frontend-andesstay) · [ms-andesstay-bff](https://github.com/MarCOCO999/ms-andesstay-bff) · [ms-andesstay-reservations](https://github.com/MarCOCO999/ms-andesstay-reservations) · [ms-andesstay-catalog](https://github.com/MarCOCO999/ms-andesstay-catalog) · [ms-andesstay-notify](https://github.com/MarCOCO999/ms-andesstay-notify) · [ms-andesstay-audit](https://github.com/MarCOCO999/ms-andesstay-audit) · [ms-andesstay-report](https://github.com/MarCOCO999/ms-andesstay-report)
