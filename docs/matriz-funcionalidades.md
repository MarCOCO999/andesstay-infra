# Matriz de funcionalidades — AndesStay

Alcance completo del proyecto AndesStay (caso DSY1107 – Desarrollo Cloud Native I) con el estado de cada funcionalidad, el componente responsable y una evidencia verificable en los repositorios (endpoint, archivo, commit o prueba). Los commits citados están en la rama `dev` de cada repositorio.

**Estados:** ✅ Implementada · 🟡 Parcial · ❌ No implementada

## Resumen

| Estado | Cantidad |
|---|---|
| ✅ Implementada | 33 |
| 🟡 Parcial | 2 |
| ❌ No implementada | 2 |
| **Total del alcance** | **37** |

**Grado de implementación:** 33 ÷ 37 = **89,2 %** (solo cuentan las implementadas y operativas).

## 1. Identidad y seguridad

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 1 | Login con Azure AD (MSAL, authorization code + PKCE, redirect) | ✅ | frontend-andesstay | `src/app/core/auth/auth-config.ts` (`MSALInstanceFactory`, `MSALGuardConfigFactory`) · commit `0404836` |
| 2 | Envío automático del JWT en cada llamada al backend | ✅ | frontend-andesstay | `MsalInterceptor` con `protectedResourceMap` hacia `bffUrl/*` en `auth-config.ts` · commit `0404836` |
| 3 | Cierre de sesión y redirección a `/login` ante un 401 | ✅ | frontend-andesstay | `src/app/core/auth/auth-error.interceptor.ts` |
| 4 | Protección de rutas del frontend según el rol del tenant | ✅ | frontend-andesstay | `src/app/core/auth/role.guard.ts` + `data.roles` en `app.routes.ts` |
| 5 | Validación del JWT (firma, issuer, audiencia, vigencia) en el BFF | ✅ | ms-andesstay-bff | `config/SecurityConfig.java`, `security/AudienceValidator.java` · commit `5e95b5b` |
| 6 | Autorización por método HTTP, ruta y rol en el BFF | ✅ | ms-andesstay-bff | `SecurityConfig.filterChain` (p. ej. `POST /api/catalog/**` solo Admin) · commit `3eedb0b` (regla `/api/rabbit/**`) |
| 7 | Revalidación del JWT y `@PreAuthorize` en cada microservicio | ✅ | reservations, catalog, audit, report, rabbit-admin | `config/SecurityConfig.java` + `security/AzureRolesConverter.java` en cada repo; `@PreAuthorize` en los controladores |

## 2. Catálogo

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 8 | Listar y consultar unidades (habitaciones y cabañas) | ✅ | ms-andesstay-catalog | `GET /api/catalog/units`, `GET /api/catalog/units/{id}` · commit `477388e` |
| 9 | Crear y editar unidades, tarifa y disponibilidad (Admin) | ✅ | ms-andesstay-catalog | `POST /api/catalog/units`, `PUT /api/catalog/units/{id}` |
| 10 | Valores agregados como lista cerrada (enum `Amenity`) | ✅ | ms-andesstay-catalog | `GET /api/catalog/amenities`, `domain/Amenity.java` |
| 11 | Reserva y liberación de cupos atómica, sin sobreventa | ✅ | ms-andesstay-catalog | `POST /api/catalog/units/{id}/reserve` y `/release` (`UPDATE … WHERE availableUnits > 0`) |
| 12 | Foto de referencia subida directo a Amazon S3 con URL prefirmada | ✅ | catalog + frontend | `POST /api/catalog/units/images/presign` · commits `a182b9d` (catalog) y `ab62113` (frontend) |

## 3. Reservas

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 13 | Crear reserva con monto calculado desde la tarifa de catalog | ✅ | ms-andesstay-reservations | `POST /api/reservations` · commit `1807d64` |
| 14 | Listar y consultar reservas | ✅ | ms-andesstay-reservations | `GET /api/reservations`, `GET /api/reservations/{id}` |
| 15 | Máquina de estados (CREADA → CONFIRMADA → CHECKIN_PENDIENTE → EN_ESTADIA → CHECKOUT / CANCELADA) | ✅ | ms-andesstay-reservations | `PUT /api/reservations/{id}/status`, `domain/ReservationStateMachine.java` |
| 16 | Pasarela de pago simulada (inmediato o al check-in) | ✅ | reservations + frontend | `POST /api/reservations/{id}/pay` · vista `features/payment` |

## 4. Mensajería con Kafka (eventos)

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 17 | Publicación de eventos de reserva en `reservations.events` | ✅ | ms-andesstay-reservations | Productor Kafka en `messaging/kafka/` · tópico visible en Kafka UI (`:8089`) |
| 18 | Auditoría: consumo de eventos y línea de tiempo por reserva | ✅ | ms-andesstay-audit | `GET /api/audit/events`, `GET /api/audit/events/reservation/{id}` · commit `54e7f7c` |
| 19 | Reportería: ocupación, tiempo de ciclo, reservas por hora y top de unidades | ✅ | ms-andesstay-report | `GET /api/report/kpis`, `GET /api/report/top-units` · commit `46fdc36` |
| 20 | Reintentos y dead-letter topic (`.DLT`) en los consumidores Kafka | ✅ | audit, report | Tópico `reservations.events.DLT`; configuración en `config/KafkaConsumerConfig.java` |

## 5. Mensajería con RabbitMQ (comandos) — EP3

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 21 | Productor de comandos de email, voucher y housekeeping | ✅ | ms-andesstay-reservations | `messaging/rabbit/ReservationCommandPublisher.java` · `ReservationCommandPublisherTest` · commit `c48494c` |
| 22 | Nombres de colas, exchanges y routing keys centralizados en `application.yml` | ✅ | notify, reservations | `andesstay.messaging` en ambos `application.yml`; `MessagingProperties.java` · commits `8fd26d0`, `c48494c` |
| 23 | Beans `Queue`, `Exchange` y `Binding` por caso de uso, en clases de configuración separadas | ✅ | notify, reservations | `config/RabbitTopologyConfig.java` (notify, 3 flujos × cola principal, reintento y DLQ) · `config/RabbitExchangesConfig.java` (reservations) |
| 24 | Consumidores `@RabbitListener` agrupados por dominio, con ACK manual | ✅ | ms-andesstay-notify | `messaging/listener/` (Email, Housekeeping, Voucher) · `EmailNotificationListenerTest` |
| 25 | Manejo de errores: reintento con espera para errores recuperables, NACK a DLQ para los no recuperables o agotados, todo registrado en log | ✅ | ms-andesstay-notify | `messaging/support/CommandFailureHandler.java`, colas `q.cmd.*.retry` y `q.cmd.*.dlq` · `CommandFailureHandlerTest` (4 casos) · commit `8fd26d0` |
| 26 | Detección de comandos no enrutables o rechazados por el broker (publisher confirms y returns) | ✅ | ms-andesstay-reservations | `config/MessagingConfig.deliveryFailureLogging` + `publisher-confirm-type`/`publisher-returns` en `application.yml` |
| 27 | Microservicio administrador: API REST para crear y eliminar colas, exchanges y bindings | ✅ | ms-andesstay-rabbit-admin | `POST/GET/DELETE /api/rabbit/queues`, `POST/DELETE /api/rabbit/exchanges`, `POST/DELETE /api/rabbit/bindings` · `service/RabbitAdminService.java` · commit `b8e7d2f` |
| 28 | Validación de entrada del administrador (nombres vacíos, prefijo `amq.`, TTL, tipo de exchange, routing keys) | ✅ | ms-andesstay-rabbit-admin | DTOs en `web/dto` con Bean Validation · `RabbitAdminControllersTest` (11 casos) |
| 29 | Protección de la topología del sistema y seguridad por rol en el administrador | ✅ | ms-andesstay-rabbit-admin | `andesstay.rabbit-admin.protected-*` · `RabbitAdminApiIntegrationTest` (401, 403, ciclo completo y 409 contra RabbitMQ real) |

## 6. Frontend

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 30 | Dashboard con resumen según el rol | ✅ | frontend-andesstay | `features/dashboard` · commit `ab62113` |
| 31 | Vistas de catálogo, reservas, detalle, pago, reportes y auditoría | ✅ | frontend-andesstay | `src/app/features/*` · commit `0404836` |

## 7. Infraestructura, despliegue y calidad

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 32 | Infraestructura local con Docker Compose (Oracle, RabbitMQ, Kafka + Zookeeper) | ✅ | andesstay-infra | `db/`, `mq/`, `kafka/compose.yml` · commit `c4d5b86` |
| 33 | `.gitignore` por tecnología (Maven en el backend, Angular en el frontend) | ✅ | todos los repos | `.gitignore` en la raíz de cada repositorio |
| 34 | Despliegue en AWS: EC2 de infraestructura, una EC2 por microservicio, API Gateway, S3, Elastic IP | 🟡 | andesstay-infra | `aws/provision.sh`, `aws/deploy-apps.sh` · commit `842b4ca`. Desplegados y operativos: los 6 microservicios previos. **Pendiente:** desplegar `ms-andesstay-rabbit-admin` en su EC2 |
| 35 | Pruebas automatizadas del backend | 🟡 | todos los microservicios | Pruebas unitarias e integración en notify, reservations y rabbit-admin (`./mvnw test`). catalog, audit, report y bff solo tienen la prueba de arranque (`contextLoads`) |
| 36 | Clúster de Kafka con 3 nodos de Zookeeper y 3 brokers | ❌ | andesstay-infra | Hoy corre 1 Zookeeper y 1 broker (`kafka/compose.yml`). Los servicios ya leen el factor de replicación de `KAFKA_TOPIC_REPLICATION_FACTOR` |
| 37 | Clúster de RabbitMQ de 2 nodos | ❌ | andesstay-infra | Hoy corre 1 nodo (`mq/compose.yml`) |

## Cómo verificar

- **Endpoints:** con el backend local (ver [README de andesstay-infra](../README.md)) o el API Gateway de AWS, con un token de un usuario del tenant con el rol correspondiente.
- **Pruebas:** `./mvnw test` en cada microservicio. Las de integración de `ms-andesstay-rabbit-admin` necesitan RabbitMQ en `localhost:5672`.
- **Mensajería:** consola de RabbitMQ (`:15672`, pestañas Queues y Exchanges) y Kafka UI (`:8089`).
