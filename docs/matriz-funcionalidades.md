# Matriz de funcionalidades — AndesStay

Alcance completo del proyecto AndesStay (caso DSY1107 – Desarrollo Cloud Native I) con el estado de cada funcionalidad, el componente responsable y una evidencia verificable en los repositorios (endpoint, archivo, commit o prueba). Los commits citados están en la rama `main` de cada repositorio.

**Estados:** ✅ Implementada · 🟡 Parcial · ❌ No implementada

## Resumen

| Estado | Cantidad |
|---|---|
| ✅ Implementada | 44 |
| 🟡 Parcial | 1 |
| ❌ No implementada | 1 |
| **Total del alcance** | **46** |

**Grado de implementación:** 44 ÷ 46 = **95,7 %** (solo cuentan las implementadas y operativas).

## 1. Identidad y seguridad

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 1 | Login con Azure AD (MSAL, authorization code + PKCE, redirect) | ✅ | frontend-andesstay | `src/app/core/auth/auth-config.ts` (`MSALInstanceFactory`, `MSALGuardConfigFactory`) · commit `0404836` |
| 2 | Envío automático del JWT en cada llamada al backend | ✅ | frontend-andesstay | `MsalInterceptor` con `protectedResourceMap` hacia `bffUrl/*` en `auth-config.ts` · commit `0404836` |
| 3 | Cierre de sesión y redirección a `/login` ante un 401 | ✅ | frontend-andesstay | `src/app/core/auth/auth-error.interceptor.ts` |
| 4 | Protección de rutas del frontend según el rol del tenant | ✅ | frontend-andesstay | `src/app/core/auth/role.guard.ts` + `data.roles` en `app.routes.ts` |
| 5 | Registro de cliente: perfil obligatorio en el primer ingreso (nombre, RUT/pasaporte, email, teléfono, país), editable desde "Mi perfil" | ✅ | frontend + reservations | `GET/PUT /api/profile/me` (`web/ProfileController.java`, `domain/GuestProfile.java`, tabla `GUEST_PROFILES`) · `core/auth/profile.guard.ts`, `features/profile` y enlace "Regístrate como cliente" en `features/login` |
| 6 | Validación del JWT (firma, issuer, audiencia, vigencia) en el BFF | ✅ | ms-andesstay-bff | `config/SecurityConfig.java`, `security/AudienceValidator.java` · commit `5e95b5b` |
| 7 | Autorización por método HTTP, ruta y rol en el BFF | ✅ | ms-andesstay-bff | `SecurityConfig.filterChain` (p. ej. `POST /api/catalog/**` solo Admin; `/api/profile/**` enrutado a reservations) · commit `3eedb0b` (regla `/api/rabbit/**`) · regla `/api/kafka/**` (solo Admin) hacia kafka-admin |
| 8 | Revalidación del JWT y `@PreAuthorize` en cada microservicio | ✅ | reservations, catalog, audit, report, rabbit-admin, kafka-admin | `config/SecurityConfig.java` + `security/AzureRolesConverter.java` en cada repo; `@PreAuthorize` en los controladores |

## 2. Catálogo

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 9 | Listar y consultar unidades (habitaciones y cabañas) | ✅ | ms-andesstay-catalog | `GET /api/catalog/units`, `GET /api/catalog/units/{id}` · commit `477388e` |
| 10 | Crear y editar unidades, tarifa y disponibilidad (Admin) | ✅ | ms-andesstay-catalog | `POST /api/catalog/units`, `PUT /api/catalog/units/{id}` |
| 11 | Valores agregados como lista cerrada (enum `Amenity`) | ✅ | ms-andesstay-catalog | `GET /api/catalog/amenities`, `domain/Amenity.java` |
| 12 | Reserva y liberación de cupos atómica, sin sobreventa | ✅ | ms-andesstay-catalog | `POST /api/catalog/units/{id}/reserve` y `/release` (`UPDATE … WHERE availableUnits > 0`) |
| 13 | Foto de referencia subida directo a Amazon S3 con URL prefirmada | ✅ | catalog + frontend | `POST /api/catalog/units/images/presign` · commits `a182b9d` (catalog) y `ab62113` (frontend) |

## 3. Reservas

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 14 | Crear reserva con monto calculado desde la tarifa de catalog y los datos del huésped tomados de su perfil | ✅ | ms-andesstay-reservations | `POST /api/reservations` · commit `1807d64` |
| 15 | Listar y consultar reservas | ✅ | ms-andesstay-reservations | `GET /api/reservations`, `GET /api/reservations/{id}` |
| 16 | Máquina de estados (CREADA → CONFIRMADA → CHECKIN_PENDIENTE → EN_ESTADIA → CHECKOUT / CANCELADA) | ✅ | ms-andesstay-reservations | `PUT /api/reservations/{id}/status`, `domain/ReservationStateMachine.java` |
| 17 | Pasarela de pago simulada (inmediato o al check-in) | ✅ | reservations + frontend | `POST /api/reservations/{id}/pay` · vista `features/payment` |
| 18 | Datos del huésped guardados en cada reserva (copia al momento de reservar) y visibles en el listado y el detalle | ✅ | reservations + frontend | Columnas `GUEST_NAME`, `GUEST_DOCUMENT`, `GUEST_EMAIL`, `GUEST_PHONE`, `GUEST_COUNTRY` en `domain/Reservation.java` · `ReservationResponse` · columna "Cliente" en `features/reservations` y bloque "Cliente" en `features/reservation-detail` |
| 19 | Reserva en el mesón: Operador/Admin ingresa los datos del huésped; si el RUT/pasaporte ya está registrado, la reserva queda en la cuenta de ese cliente | ✅ | reservations + frontend | Campo `guest` de `CreateReservationRequest` y `ReservationService.create` (guestId `MESON:<documento>` si no tiene cuenta) · sección "Datos del huésped" en `features/reservations` |

## 4. Mensajería con Kafka (eventos)

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 20 | Publicación de eventos de reserva en `reservations.events` (DTO JSON, key = `reservationId`, después del commit, `acks=all` + idempotencia, resultado de cada envío en el log) | ✅ | ms-andesstay-reservations | `messaging/kafka/ReservationEventPublisher.java` · `ReservationEventPublisherTest` (key, envío solo tras commit, nada si hay rollback) |
| 21 | Auditoría: consumo de eventos, línea de tiempo por reserva y publicación normalizada en `audit.timeline` | ✅ | ms-andesstay-audit | `messaging/ReservationEventListener.java` → `service/AuditRecordingService.java` · `messaging/AuditTimelinePublisher.java` · `GET /api/audit/events/reservation/{id}` |
| 22 | Reportería: ocupación, tiempo de ciclo, reservas por hora y top de unidades | ✅ | ms-andesstay-report | `GET /api/report/kpis`, `GET /api/report/top-units` · `service/ReservationMetricsService.java` |
| 23 | Consumo de `audit.timeline` (compactado): estado actual de cada reserva sin consultar la base de reservations | ✅ | ms-andesstay-report | `messaging/AuditTimelineListener.java` → `service/ReservationSnapshotService.java` (descarta entradas antiguas, tombstones) · `GET /api/report/status-summary` · `ReservationSnapshotServiceTest` |
| 24 | Manejo de errores en los consumidores: validación del payload (`@Valid`), JSON ilegible y payload inválido directo al DLT, 3 reintentos con backoff exponencial para errores transitorios, log contextual de cada intento y monitor de los DLT | ✅ | audit, report | `config/KafkaConsumerConfig.java`, `config/KafkaListenerValidationConfig.java`, `messaging/DeadLetterMonitor.java` · tópicos `reservations.events.DLT` y `audit.timeline.DLT` · `ReservationEventValidationTest` |
| 25 | Parámetros de los tópicos por flujo de datos (particiones, réplicas, `min.insync.replicas`, retención, `cleanup.policy`) declarados por el servicio dueño de cada tópico y en un script replicable | ✅ | reservations, audit, report, andesstay-infra | `andesstay.kafka.topics` en `application.yml` + `config/KafkaTopicsConfig.java` · `kafka/scripts/create-topics.sh` (`reservations.events` delete 7 días, `audit.timeline` compactado, DLT 1 partición 14 días) |
| 26 | Consumer groups por flujo: audit y report reciben todos los eventos con grupos distintos; 3 consumidores por grupo (1 por partición) con rebalanceo cooperativo; grupos aparte para el timeline y los monitores de DLT | ✅ | audit, report | `andesstay.kafka.consumer-groups` y `concurrency` en `application.yml`; `groupId` en cada `@KafkaListener` |
| 27 | Microservicio administrador de Kafka: API REST para inspeccionar el clúster y crear, listar, modificar (configuración y particiones) y eliminar tópicos | ✅ | ms-andesstay-kafka-admin | `GET /api/kafka/cluster`, `GET/POST/DELETE /api/kafka/topics`, `PATCH /api/kafka/topics/{name}/configs`, `POST /api/kafka/topics/{name}/partitions` · `service/TopicAdminService.java` |
| 28 | Administración de consumer groups: miembros, lag por partición, reset de offsets (earliest, latest, timestamp) y eliminación; script de operaciones por consola | ✅ | ms-andesstay-kafka-admin, andesstay-infra | `GET /api/kafka/consumer-groups/{id}`, `POST .../offsets/reset`, `DELETE ...` · `service/ConsumerGroupAdminService.java` · `kafka/scripts/kafka-ops.sh` |
| 29 | Validación, protección de los tópicos y grupos del sistema y seguridad por rol en el administrador de Kafka | ✅ | ms-andesstay-kafka-admin | `service/TopicConfigRules.java`, `andesstay.kafka-admin.protected-*` · `KafkaAdminControllersTest`, `TopicAdminServiceTest`, `ConsumerGroupAdminServiceTest` · `KafkaAdminApiIntegrationTest` (401, 403, 3 brokers, ciclo completo de un tópico, lag y reset contra el clúster real) |

## 5. Mensajería con RabbitMQ (comandos) — EP3

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 30 | Productor de comandos de email, voucher y housekeeping | ✅ | ms-andesstay-reservations | `messaging/rabbit/ReservationCommandPublisher.java` · `ReservationCommandPublisherTest` · commit `c48494c` |
| 31 | Nombres de colas, exchanges y routing keys centralizados en `application.yml` | ✅ | notify, reservations | `andesstay.messaging` en ambos `application.yml`; `MessagingProperties.java` · commits `8fd26d0`, `c48494c` |
| 32 | Beans `Queue`, `Exchange` y `Binding` por caso de uso, en clases de configuración separadas | ✅ | notify, reservations | `config/RabbitTopologyConfig.java` (notify, 3 flujos × cola principal, reintento y DLQ) · `config/RabbitExchangesConfig.java` (reservations) |
| 33 | Consumidores `@RabbitListener` agrupados por dominio, con ACK manual | ✅ | ms-andesstay-notify | `messaging/listener/` (Email, Housekeeping, Voucher) · `EmailNotificationListenerTest` |
| 34 | Manejo de errores: reintento con espera para errores recuperables, NACK a DLQ para los no recuperables o agotados, todo registrado en log | ✅ | ms-andesstay-notify | `messaging/support/CommandFailureHandler.java`, colas `q.cmd.*.retry` y `q.cmd.*.dlq` · `CommandFailureHandlerTest` (4 casos) · commit `8fd26d0` |
| 35 | Detección de comandos no enrutables o rechazados por el broker (publisher confirms y returns) | ✅ | ms-andesstay-reservations | `config/MessagingConfig.deliveryFailureLogging` + `publisher-confirm-type`/`publisher-returns` en `application.yml` |
| 36 | Microservicio administrador: API REST para crear y eliminar colas, exchanges y bindings | ✅ | ms-andesstay-rabbit-admin | `POST/GET/DELETE /api/rabbit/queues`, `POST/DELETE /api/rabbit/exchanges`, `POST/DELETE /api/rabbit/bindings` · `service/RabbitAdminService.java` · commit `b8e7d2f` |
| 37 | Validación de entrada del administrador (nombres vacíos, prefijo `amq.`, TTL, tipo de exchange, routing keys) | ✅ | ms-andesstay-rabbit-admin | DTOs en `web/dto` con Bean Validation · `RabbitAdminControllersTest` (11 casos) |
| 38 | Protección de la topología del sistema y seguridad por rol en el administrador | ✅ | ms-andesstay-rabbit-admin | `andesstay.rabbit-admin.protected-*` · `RabbitAdminApiIntegrationTest` (401, 403, ciclo completo y 409 contra RabbitMQ real) |

## 6. Frontend

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 39 | Dashboard con resumen según el rol | ✅ | frontend-andesstay | `features/dashboard` · commit `ab62113` |
| 40 | Vistas de catálogo, reservas, detalle, pago, reportes y auditoría | ✅ | frontend-andesstay | `src/app/features/*` · commit `0404836` |

## 7. Infraestructura, despliegue y calidad

| # | Funcionalidad | Estado | Componente | Evidencia |
|---|---|---|---|---|
| 41 | Infraestructura local con Docker Compose (Oracle, RabbitMQ, Kafka + Zookeeper + Kafka UI) | ✅ | andesstay-infra | `db/`, `mq/`, `kafka/compose.yml` · commit `c4d5b86` |
| 42 | `.gitignore` por tecnología (Maven en el backend, Angular en el frontend) | ✅ | todos los repos | `.gitignore` en la raíz de cada repositorio |
| 43 | Despliegue en AWS: EC2 de infraestructura, una EC2 por microservicio (7), API Gateway, S3, Elastic IP | ✅ | andesstay-infra | `aws/provision.sh`, `aws/deploy-apps.sh`, `aws/redeploy.sh` · commits `842b4ca`, `21b29c7`. Los 7 microservicios responden `UP`; `GET https://e94n72mnmk.execute-api.us-east-1.amazonaws.com/api/rabbit/queues/q.cmd.email` sin token responde `401` (ruta publicada y protegida) |
| 44 | Pruebas automatizadas del backend | 🟡 | todos los microservicios | Pruebas unitarias e integración en notify, reservations, rabbit-admin y kafka-admin, y unitarias de la mensajería Kafka en audit y report (`./mvnw test`). catalog y bff solo tienen la prueba de arranque (`contextLoads`) |
| 45 | Clúster de Kafka con 3 nodos de Zookeeper y 3 brokers (RF 3, `min.insync.replicas` 2), creación de tópicos y Kafka UI | ✅ | andesstay-infra | `kafka/compose.yml` (ensemble `zookeeper-1..3`, `kafka-1..3`, `kafka-init`, `kafka-ui`) · en AWS con `aws/kafka-cluster.sh` |
| 46 | Clúster de RabbitMQ de 2 nodos | ❌ | andesstay-infra | Hoy corre 1 nodo (`mq/compose.yml`) |

## Cómo verificar

- **Endpoints:** con el backend local (ver [README de andesstay-infra](../README.md)) o el API Gateway de AWS, con un token de un usuario del tenant con el rol correspondiente.
- **Pruebas:** `./mvnw test` en cada microservicio. Las de integración de `ms-andesstay-rabbit-admin` necesitan RabbitMQ en `localhost:5672`, y las de `ms-andesstay-kafka-admin` el clúster Kafka en `localhost:9092`.
- **Mensajería:** consola de RabbitMQ (`:15672`, pestañas Queues y Exchanges), Kafka UI (`:8089`: brokers, tópicos, consumer groups) y `kafka/scripts/kafka-ops.sh`.
