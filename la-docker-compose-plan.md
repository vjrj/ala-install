# Plan: nuevo repo `la-docker-compose`

Contexto: ver también `docker-plan.md` y `AGENTS.md` en la raíz del repo.

No hacer commits sin aprobación.
Debe funcionar con los inventarios que están en /data/la-toolkit/config/lademo/lademo-inventories/

## El problema real (tras leer inventarios)

El inventario de lademo (`/data/la-toolkit/config/lademo/lademo-inventories/`) revela **3 capas de hostnames**:

### 1. Hostnames externos (URLs públicas)
No cambian. Ej: `collectory_url = https://collections.l-a.site`.

### 2. Hostnames de BBDDs — deben venir del inventario generado

> [!IMPORTANT]
> En una **misma máquina**, un servicio no puede estar simultáneamente en VM y en docker-compose. Pero el portal puede ser **mixto entre máquinas**: unas VM y otras docker-compose. `docker_extra_hosts` ya resuelve esto — lista IPs reales independientemente del destino (VM o container).

```
Máquina 1 (docker-compose): cas, collectory
Máquina 2 (VM):             solr, cassandra     ← docker_extra_hosts apunta aquí
Máquina 3 (docker-compose): bie, namematching
```

Esto permite **migración progresiva**: mover servicios de VM a docker-compose sin romper el portal.

Cuando `generator-living-atlas` genera en modo docker-compose, debe producir hostnames de containers en vez de `localhost` para las BBDDs locales:
```ini
collectory_db_host_address = mysql    # container local
user_store_db_hostname = mysql
ticket_registry_db_hostname = mongodb
```

### 3. Networking multi-host Docker

```ini
[gbif-es-docker-cluster-2023-1_group:vars]
nginx_docker_internal_aliases='["auth.l-a.site","collections.l-a.site",...]'
# ↑ dominios que el nginx de ESTA máquina responde localmente

docker_extra_hosts='["species.l-a.site:172.16.16.56","images.l-a.site:172.16.16.78",...]'
# ↑ dominios de OTRAS máquinas (VM o docker-compose), con sus IPs reales
```

- nginx registra `nginx_docker_internal_aliases` como aliases de red Docker interna
- Todos los containers llevan `extra_hosts` con las IPs de los otros hosts del cluster

---

## Repos relacionados: cambios mínimos necesarios

### `generator-living-atlas` — parche para hostnames de containers

El generator ya soporta `docker_compose` parcialmente (`services.js` tiene `docker_compose` y `docker_common` como grupos; `libs.js` conoce `LA_use_docker_compose`, `LA_docker_extra_hosts_by_host`, `LA_variable_docker_mail_development_mode`).

**El único parche necesario**: cuando `LA_use_docker_compose` es `true` para un host, el generator debe producir hostnames de containers en vez de `localhost` para las BBDDs locales:

```diff
# group_vars del host docker_compose (generado por yo living-atlas)
-collectory_db_host_address: localhost
+collectory_db_host_address: mysql      # container local
-user_store_db_hostname: localhost
+user_store_db_hostname: mysql
-ticket_registry_db_hostname: localhost
+ticket_registry_db_hostname: mongodb
```

El generator ya sabe qué servicios van en cada host, así que puede inferir qué hostnames corresponden a containers locales y cuáles a máquinas remotas (que ya maneja con `docker_extra_hosts`).

### `la-toolkit` — parche mínimo para invocar `la-docker-compose`

la-toolkit (Flutter) ya soporta Docker Compose a nivel de UI: los operadores pueden designar máquinas como hosts Docker Compose y asignarles servicios. El único cambio necesario:

Cuando la máquina destino es de tipo `docker_compose`, la-toolkit debe llamar los playbooks de `la-docker-compose` en vez de los de `ala-install` directamente:

```diff
# En la-toolkit, al lanzar un playbook contra un host docker_compose:
-ansiblew --alainstall=../ala-install docker_compose
+ansiblew --alainstall=../la-docker-compose docker_compose
```

Esto es trivial si `la-toolkit` ya parametriza el path de `ala-install`.

---

## Repo: `la-docker-compose`

Análogo a `la-docker-images` (que gestiona el build), este repo gestiona **solo la orquestación**: genera el `docker-compose.yml`, inicializa BBDDs, arranca servicios. **Nunca hace `docker build`** — consume imágenes de `la-docker-images` o del registry.


```
la-docker-compose/
  ansible.cfg           ← roles_path = ../ala-install/ansible/roles:roles
  roles/
    la-compose/
      defaults/main.yml
      tasks/
        main.yml
        db-init.yml          ← init MySQL/MongoDB via port-forward
        compose-generate.yml ← genera docker-compose.yml por host
        compose-validate.yml
      templates/
        docker-compose.yml.j2   ← base con include:
        docker-compose.env.j2   ← passwords
        infrastructure/
          nginx.yml.j2
          mysql.yml.j2
          mongodb.yml.j2
          postgres.yml.j2
          ssl-certs.yml.j2     ← ver sección SSL más abajo
          mailhog.yml.j2       ← modo dev
          postfix.yml.j2       ← modo prod
          gatus.yml.j2
          db-backup.yml.j2
          branding.yml.j2
        services/
          cas.yml.j2
          collectory.yml.j2
          ...
      molecule/
        default/             ← tests locales con Docker driver
  playbooks/
    site.yml             ← orquestador principal
    db-init.yml          ← init BBDDs aislado
    config-gen.yml       ← solo genera config, sin deploy
  inventories/
    local/               ← inventario mínimo para molecule/CI
      hosts.ini
      group_vars/
```

---

## Servicios en el docker-compose.yml (por host)

```
/data/docker-compose/
  docker-compose.yml    ← base con include:
  .env                  ← passwords
  infrastructure/       ← generado por la-compose templates
    nginx.yml
    ssl-certs.yml
    mysql.yml
    mongodb.yml
    gatus.yml
    branding.yml
    mailhog | postfix.yml
    db-backup.yml
  services/             ← cada fragmento generado por su propio rol ala-install
    cas.yml             ← generado por roles/cas5/tasks/docker-tasks.yml
    collectory.yml      ← generado por roles/collectory/tasks/docker-tasks.yml
    ...
```

---

## Servicios de soporte críticos

### Branding
- Container nginx estático que sirve los assets CSS/JS del branding
- Construido por `la-docker-images` (o desde git URL en la-docker-compose)
- `nginx_docker_internal_aliases` incluye el dominio de branding (`branding.l-a.site`)
- Todos los servicios lo referencian pero es solo HTTP estático — fácil de desplegar primero

### SSL Certs
- **Sin certs válidos, nada funciona** — debe configurarse antes que cualquier servicio
- Estrategia: compartir un volumen `la-site-certs` montado en el container nginx si así se selecciona en los inventarios (si se usa un dominio de prueba con use_la_site_certs=true)
- El cert se obtiene/renueva en el host (letsencrypt, certbot, o certs de la organización)
- El playbook verifica la existencia y validez del cert antes de continuar
- Variable clave: `ssl=true`, `ssl_certificate_server_dir`, `ssl_cert_file`, `ssl_key_file`
- El fragment `ssl-certs.yml.j2` monta el directorio del host como volumen read-only en nginx

### Gatus (monitorización)

Da visibilidad de qué servicios funcionan — imprescindible en deploys. **Problema**: Gatus vive en un solo host, pero cada rol (`nginx_vhost`, servicios individuales) genera endpoints de monitorización en hosts diferentes. Los endpoints deben llegar todos al host de Gatus.

**Estrategia: generación centralizada desde hostvars**

En Ansible, el host de Gatus tiene acceso a `hostvars` de todos los hosts del inventario. El rol `la-compose` en el host de Gatus itera sobre todos los servicios habilitados en el cluster (no solo los locales) y genera los endpoints en un solo paso:

```yaml
# En el host de Gatus, generar endpoints de TODOS los servicios del cluster
- name: Generate Gatus endpoints for all cluster services
  template:
    src: gatus-endpoint.yaml.j2
    dest: /data/gatus/config/{{ item.key }}.yaml
  loop: "{{ all_cluster_services }}"    # computado de hostvars de todos los hosts
  delegate_to: "{{ gatus_host }}"
  when: "'gatus' in physical_server_groups"
```

Donde `all_cluster_services` se calcula en `setup-facts.yml` mirando los `physical_server_groups` de **todos** los hosts en `docker_compose_hosts`, no solo el local.

Alternativa más simple: el template de Gatus en el host de Gatus itera sobre `groups['docker_compose_hosts']` y para cada host accede a `hostvars[host].services_enabled` — sin delegation, sin fetch/push.

```yaml
# gatus-config.yml.j2 (en el host de gatus)
endpoints:
{% for dc_host in groups['docker_compose_hosts'] %}
{% for svc in hostvars[dc_host].get('services_enabled', []) %}
  - name: {{ svc }}
    url: https://{{ hostvars[dc_host][svc + '_hostname'] | default('') }}
    ...
{% endfor %}
{% endfor %}
```

Variables: `monitoring_enabled`, `gatus_host` (hostname del host de Gatus), dominio en `nginx_docker_internal_aliases`.

Muchas de las configuraciones de gatus las genera el rol nginx_vhost que añade todos los paths, por ej. Que no funcione un path es señal de que algo no va bien.

### Mail (Postfix/Mailhog)
- **Modo dev** (`docker_mail_development_mode: true`): Mailhog — captura todo, nada sale
- **Modo prod**: Postfix con relay hacia servidor SMTP externo
- Variables: `email_sender`, `email_sender_server`, `email_sender_password`, `email_allowed_domains`
- Todos los servicios apuntan a `postfix:25` o `mailhog:1025` internamente

### Backups de BBDDs
- `db-backup.yml.j2` — container periódico que hace dump de MySQL/MongoDB/PostgreSQL
- Monta `/data/docker-compose/db-backups/` como volumen
- Solo activo si `enable_db_backup: true`
- Complementa (no reemplaza) los backups del host

---

## Networking: `docker_extra_hosts` y aliases

```yaml
# x-common.yml.j2 — fragmento YAML reutilizable (YAML anchors)
x-extra-hosts: &extra_hosts
  extra_hosts:
{% for entry in docker_extra_hosts %}
    - "{{ entry }}"
{% endfor %}

# Cada servicio hereda con:
services:
  cas:
    <<: *extra_hosts
    ...
  collectory:
    <<: *extra_hosts
    ...

# nginx registra los dominios locales:
  nginx:
    networks:
      internal:
        aliases:
{% for alias in nginx_docker_internal_aliases %}
          - {{ alias }}
{% endfor %}
```

---

## Lo que no podemos olvidar del POC

Tras revisar el rol `docker-compose` del POC (../ala-install-docker) tarea a tarea, estos son los mecanismos clave que deben preservarse:

### 1. `setup-facts.yml` — el cerebro del despliegue

Calcula `physical_server_groups`: para cada host del grupo `docker_compose`, busca todos los alias de inventario que comparten el mismo `ansible_host` y extrae los grupos de servicio. Así sabe **qué servicios van en esa máquina**.

De ahí deriva automáticamente:
- `services_enabled` — lista de servicios activos en ese host (usando `docker_services_desc` como mapa)
- `enable_mysql`, `enable_postgres`, `enable_mongo` — flags de BBDDs necesarias (según qué servicios están en ese host)

**Esto es fundamental**: sin este cálculo no se puede saber qué fragmentos de compose generar.

### 2. `docker-services-desc.yaml` — el diccionario central de servicios

Mapea cada servicio a: grupo de Ansible, rol de ala-install, artefacto, repositorio, variable de versión, `isSubService`/`parentService` (ej. userdetails/apikey son sub-servicios de cas). 28 servicios catalogados.

**No recrear desde cero** — este fichero existe y está bien, llevarlo a `la-docker-compose/roles/la-compose/vars/`.

### 3. `ensure-db-volumes.yml` — volúmenes externos con prefijo `la_`

Crea volúmenes Docker **externos** (con `docker_volume` module) para que `docker compose down -v` no los borre accidentalmente:
- `la_mysql-data`, `la_postgres-data`, `la_mongodb-data`
- `la_solr-data`, `la_cassandra-data`, `la_elasticsearch-data`
- `la-site-certs` (SSL, si `use_la_site_certs: true`)
- `la_branding-assets`, `la_gatus-data`

Cada volumen solo se crea si el servicio correspondiente está en ese host.

### 4. `determine-java-versions.yml` — **NO necesario** en `la-docker-compose`

Descarga `dependencies.yaml` de la-toolkit-backend para determinar la imagen base Java por versión de servicio. **Esto ya lo hace `la-docker-images`** — la versión Java está baked-in en la imagen. `la-docker-compose` solo necesita el tag de la imagen (la versión del servicio). Este fichero **no se porta**.

### 5. Mail: set_fact de variables antes de generar compose

El POC sobreescribe `mail_smtp_host`, `mail_smtp_port`, `mail_host` antes de llamar al rol `nginx_vhost` para mailhog. También añade el dominio mailhog/branding a `nginx_docker_internal_aliases` dinámicamente. Hay que preservar este orden: **primero set_facts de mail y branding, luego generar fragmentos**.

### 6. Validaciones post-generación y inicializaciones adicionales

- `validate-docker-compose.yml`: ejecuta `docker compose config` para validar el YAML generado
- Check de referencias `ala-install` en los ficheros generados (rutas absolutas que romperían en containers)
- Verificación de certs SSL: `stat` sobre `ssl_cert_file` y `ssl_key_file` + assert

#### Inicialización de Solr
El container Solr necesita sus colecciones y configuraciones previas al primer arranque:
```yaml
- name: Create Solr init directory
  file:
    path: "{{ docker_compose_data_dir }}/solr/init"
    state: directory

- name: Copy Solr config files from solrcloud_config role
  copy:
    src: "{{ playbook_dir }}/roles/solrcloud_config/files/"
    dest: "{{ docker_compose_data_dir }}/solr/init/"
```
El container Solr monta `./solr/init/` y aplica las colecciones en el arranque via script de init.

#### Inicialización de Cassandra
El schema de Cassandra (usado por biocache para anotaciones y queries persistentes) se copia del rol `biocache3-db` y se aplica en el primer arranque del container:
```yaml
- name: Create Cassandra init directory
  file:
    path: "{{ docker_compose_data_dir }}/cassandra/init"
    state: directory

- name: Copy Cassandra schema
  copy:
    src: "{{ playbook_dir }}/roles/biocache3-db/files/cassandra/cassandra3-schema.txt"
    dest: "{{ docker_compose_data_dir }}/cassandra/init/schema.cql"
```
El container Cassandra ejecuta `schema.cql` en el arranque si la base de datos está vacía.

---

## Estrategia para minimizar el PR a ala-install

Esta es la decisión de arquitectura más importante: **lo que le pedimos a ala-install define el tamaño del PR**.

### El contrato con ala-install: sólo config, no orquestación

Los roles de ala-install ya hacen dos cosas distintas:
1. **Instalar y configurar** el servicio en la VM (paquetes, systemd, usuarios...)
2. **Generar los ficheros de config** del servicio (`/data/<servicio>/config/`)

Para docker-compose, solo necesitamos la parte 2. La parte 1 es trabajo del Dockerfile (ya en `la-docker-images`).

Pero hay otras tareas que hacen (creación de usuarios, apikeys, dbschemas, etc) que no hay que olvidar ni dejar de usar.

**La clave**: los roles de ala-install ya escriben configs en `/data/<servicio>/config/` usando variables del inventario. En un host docker-compose, esos mismos ficheros se montan como volúmenes en el container. **No hay que cambiar nada en el rol si las vars ya vienen bien del inventario.**

### Los fragmentos de `docker-compose/services/*.yml` van en `la-docker-compose`

En vez de que cada rol ala-install genere su propio fragmento (lo que obliga a tocar todos los roles), **`la-docker-compose` tiene sus propios templates de servicio**. Esto significa:

- `la-docker-compose/roles/la-compose/templates/services/cas.yml.j2`
- `la-docker-compose/roles/la-compose/templates/services/collectory.yml.j2`
- ...

Ala-install no sabe nada de docker-compose. PR = cero cambios por este motivo.

### El único cambio necesario en ala-install: guards en tasks VM-only

Cuando llamamos a un rol ala-install desde `la-docker-compose` para generar configs, algunas tasks van a fallar o no tienen sentido (instalar apt, configurar systemd, crear usuarios del sistema...). La solución mínima:

```yaml
# En cada task que no aplica a containers, añadir:
- name: Install collectory package
  apt:
    name: "{{ collectory_app }}"
  when: deployment_type | default('vm') != 'container'   # ← único cambio
```

Esto es un PR muy pequeño y seguro: solo añade un `when:` a tasks existentes. No cambia la lógica para VMs en absoluto. Además, como `deployment_type` no está definido en inventarios VM, el `default('vm')` garantiza que los deploys VM no se ven afectados.

### Lo que NO hay que tocar en ala-install

| Rol | Cambio en ala-install | Por qué no es necesario |
|---|---|---|
| `cas5` | Solo guards en `apt`, `systemd` | Config ya va a `/data/cas/config/` |
| `collectory` | Solo guards en `apt`, `systemd` | Config ya va a `/data/collectory/config/` |
| `nginx_vhost` | Ya tiene `nginx_vhost_fast_mode: true` | Skippea handlers |
| `common` | Guards en tareas de sistema | No configura ficheros de app |
| Fragmentos compose | 🚫 Cero cambios | Van en `la-docker-compose/templates/` |
| Gatus endpoints | 🚫 Cero cambios | Se generan desde `la-docker-compose` | 

### Resultado: PR mínimo a ala-install

El PR a ala-install consiste únicamente en:
- `when: deployment_type | default('vm') != 'container'` en las tasks de instalación/systemd de los ~8 roles afectados
- Ningún template nuevo, ningún fichero nuevo, ningún cambio de lógica
- Fácilmente revisable, bajo riesgo para deploys VM

---

## Auditoría de tareas por rol

Antes de implementar, para cada rol de ala-install que vayamos a invocar desde `la-compose`, hay que revisar **tarea a tarea**:

| Tarea en ala-install | ¿Necesaria en container? | ¿Ya la hace `la-docker-images`? | Equivalente en container |
|---|---|---|---|
| Instalar paquete (apt) | ❌ No | ✅ Sí, en la imagen base | — |
| Configurar Java (JAVA_HOME, etc.) | ❌ No | ✅ Sí, en la imagen base | — |
| Crear usuario del sistema | ❌ No | ✅ Sí, en la imagen base | — |
| Crear directorios de logs/config | ✅ Sí | ❌ No | Crear con Ansible en el host y montar como volumen |
| Generar fichero de config (template) | ✅ Sí | ❌ No | Igual, en `/data/<servicio>/config/` |
| Instalar/copiar WAR/JAR | ❌ No | ✅ Sí, en la imagen | — |
| Configurar systemd/tomcat | ❌ No | ✅ Sí, en la imagen (entrypoint) | — |
| Generar vhost nginx | ✅ Sí | ❌ No | En `/etc/nginx/sites-enabled/` montado en el container nginx |
| Restart nginx/servicio | ❌ No (skip_handlers) | — | `docker compose restart nginx` si hace falta |
| Crear schema/usuario en BBDD | ✅ Sí | ❌ No | Parte del DB Init (port-forward) |
| Configurar firewall (ufw) | ❌ No | — | Gestión de red Docker |

> [!NOTE]
> Para cada rol hay que hacer este análisis antes de incluirlo. El fichero `vars/docker-services-desc.yaml` del POC era un buen punto de partida — revisarlo como referencia.

El proceso por rol:
1. Listar todas las tasks del rol (`main.yml` + tasks incluidas)
2. Clasificar cada una según la tabla anterior
3. Las tasks de tipo `❌ No` se saltan con `when: deployment_type != 'container'` en ala-install, o simplemente no se llaman desde `la-compose`
4. Las tasks `✅ Sí` se reutilizan tal cual

---

## Generación del `.env`

El fichero `.env` es crítico: contiene **todas las variables de entorno** que los containers necesitan (passwords de BBDD, claves de API, configuración sensible). El POC ya lo generaba correctamente con `docker-compose.env.j2`.

Principios:
- **Una sola fuente de verdad**: las variables vienen del inventario de Ansible (nunca hardcodeadas en el template)
- El `.env` lo lee Docker Compose automáticamente y las inyecta en todos los servicios que lo referencian con `${VAR_NAME}`
- No incluir variables que ya están en `/data/<servicio>/config/` (evitar duplicación)
- Variables típicas en `.env`:

```dotenv
# BBDDs
MYSQL_ROOT_PASSWORD={{ mysql_root_password }}
MONGODB_ROOT_PASSWORD={{ mongodb_root_password }}
POSTGRES_PASSWORD={{ postgresql_password }}

# Passwords de aplicaciones
COLLECTORY_DB_PASSWORD={{ collectory_db_password }}
USER_STORE_DB_PASSWORD={{ user_store_db_password }}
APIKEY_DB_PASSWORD={{ apikey_db_password }}

# JAVA_OPTS por servicio
CAS_JAVA_OPTS={{ cas_java_opts | default(tomcat_java_opts) }}
COLLECTORY_JAVA_OPTS={{ collectory_java_opts | default(tomcat_java_opts) }}

# Versiones de imágenes (permite rollback fácil)
CAS_VERSION={{ cas_version }}
COLLECTORY_VERSION={{ collectory_version }}
```

Las versiones en `.env` permiten hacer rollback cambiando solo esa línea y haciendo `docker compose up -d`.

---

## DB Init: estrategia port-forward temporal

```
1. Generar compose con puertos MySQL/MongoDB expuestos (expose_for_init: true)
2. docker compose up -d mysql mongodb
3. Esperar healthcheck de ambos containers
4. Desde host Ansible: conectar a 127.0.0.1:3306 → ejecutar cas5-dbs (reutilizar de ala-install)
5. docker compose up -d cas  (Flyway migrations automáticas)
6. Esperar que CAS esté healthy
7. Registrar servicios OIDC
8. docker compose down
9. Regenerar compose SIN puertos expuestos
10. docker compose up -d  (estado final de producción)
```

Reutiliza `cas5-dbs` de ala-install sin modificarlo.

---

## Orden de despliegue recomendado

1. **SSL certs** — sin esto lo demás no arranca
2. **Branding** — dependencia visual de todos los servicios
3. **Infraestructura**: MySQL, MongoDB, nginx
4. **DB Init**: crear schemas y usuarios
5. **CAS + userdetails + apikey** — auth antes que cualquier servicio protegido
6. **Collectory** — primera comprobación funcional end-to-end
7. **Gatus** — para tener visibilidad del resto del despliegue
8. **Mail** — necesario para cuentas y alertas
9. Resto de servicios

---

## Testabilidad local

### Molecule
```yaml
# molecule/default/molecule.yml
driver:
  name: docker
platforms:
  - name: la-test
    image: ubuntu:22.04
    groups: [docker_compose, cas-servers, collectory]
```

```bash
molecule test       # converge + idempotence + verify
molecule converge   # solo aplicar
molecule verify     # solo assertions
```

### Assertions en verify.yml
- `docker-compose.yml` generado y válido (`docker compose config` sin errores)
- Fragmentos de infraestructura/servicios presentes
- `.env` contiene variables esperadas
- `extra_hosts` correctos en el compose generado
- Dominio de branding en `nginx_docker_internal_aliases`

### CI rápido (sin infra real)
```bash
ansible-playbook --syntax-check playbooks/site.yml -i inventories/local/
yamllint roles/la-compose/
ansible-lint roles/la-compose/
ansible-playbook playbooks/config-gen.yml -i inventories/local/ --check --diff
docker compose -f /data/docker-compose/docker-compose.yml config
```

---

## Modo desarrollo local

Un caso de uso crítico: el desarrollador quiere probar **uno o dos servicios en local** (branding, collectory...) mientras consume el resto del portal desde producción (CAS real, namematching real, etc.).

### Patrón: dev-overlay

```
Browser → localhost/collections  →  nginx local  →  collectory container
Browser → localhost/cas          →  nginx local  →  proxy_pass → auth.l-a.site (CAS real)
collectory container → auth.l-a.site  →  resuelto via docker_extra_hosts (IP pública real)
```

### Inventario `inventories/dev/hosts.ini`

El patrón `localhost.servicio` es fundamental: Ansible usa el hostname de inventario (no `ansible_host`) como clave para separar `hostvars`. Si todos los servicios usaran el mismo `localhost` como hostname, compartirían hostvars y las variables de grupo se pisarían unas a otras. Con `localhost.collectory`, `localhost.cas-servers`, etc., cada servicio tiene su propio espacio de variables.

```ini
[docker_compose]
localhost.collectory                  ansible_host=localhost ansible_connection=local
localhost.cas-servers                 ansible_host=localhost ansible_connection=local
localhost.branding                    ansible_host=localhost ansible_connection=local
localhost.bie-hub                     ansible_host=localhost ansible_connection=local
localhost.bie-index                   ansible_host=localhost ansible_connection=local
localhost.biocache-hub                ansible_host=localhost ansible_connection=local
localhost.biocache-service-clusterdb  ansible_host=localhost ansible_connection=local
localhost.image-service               ansible_host=localhost ansible_connection=local
localhost.species-list                ansible_host=localhost ansible_connection=local
localhost.namematching-service        ansible_host=localhost ansible_connection=local
localhost.logger-service              ansible_host=localhost ansible_connection=local
localhost.gatus                       ansible_host=localhost ansible_connection=local
# ... resto de servicios

# Grupos de servicio — necesarios para que los roles accedan a group_vars
[collectory]
localhost.collectory

[cas-servers]
localhost.cas-servers

[branding]
localhost.branding

[bie-hub]
localhost.bie-hub

# ... etc. cada servicio en su propio grupo
```

En modo dev, el desarrollador comenta o elimina los servicios que no necesita levantar localmente — el resto sigue siendo servido por el portal real vía `proxy_remote_portal`.


### nginx local: proxy dual

El nginx local opera en dos modos:
- **Rutas locales** (los servicios del inventario dev) → container local
- **Resto** → `proxy_pass` al portal remoto (para que los links rotos del UI funcionen)

### Variables de separación dev/prod

| Variable | Dev | Prod |
| --- | --- | --- |
| `ansible_host` | `localhost` | IP real del servidor |
| `cas_server_url_prefix` | URL del CAS real | URL del CAS propio |
| `docker_extra_hosts` | IPs del portal remoto | IPs de los otros hosts del cluster |
| `proxy_remote_portal` | URL del portal real | no aplica |
| `deployment_type` | `container-dev` | `container` |

### Flujo de trabajo típico

```bash
# 1. Generar config local para un solo servicio
ansible-playbook playbooks/config-gen.yml -i inventories/dev/ --limit collectory

# 2. Levantar
docker compose up -d

# 3. Cambiar template, recargar
docker compose restart collectory

# 4. Añadir otro servicio al inventario dev y repetir
```

> [!NOTE]
> El modo dev es un inventario separado, no una variable booleana en el mismo inventario de prod. Esto garantiza que nunca se confunden las dos configuraciones.

---

## Fases de implementación

### Fase 1 — Esqueleto + CAS + infra básica
- Repo con `ansible.cfg` y estructura de directorios
- Inventario local mínimo (1 host, CAS + MySQL + MongoDB)
- Templates: nginx, mysql, mongodb, cas, SSL certs
- `config-gen.yml` genera compose válido
- Molecule: `molecule test` pasa

### Fase 2 — Servicios de soporte
- Branding, Gatus, Mail (mailhog modo dev), DB Backup
- Orden de despliegue documentado y probado

### Fase 3 — DB Init robusto
- `playbooks/db-init.yml` con estrategia port-forward
- Reutilizar `cas5-dbs` de ala-install sin modificarlo
- Tests que verifican schemas y usuarios tras init

### Fase 4 — Multi-host networking
- Soporte completo `nginx_docker_internal_aliases` + `docker_extra_hosts`
- Inventario local que simula 2 hosts
- Tests de que `extra_hosts` aparecen en el compose generado

### Fase 5 — Collectory + resto de servicios
- Ampliar plantillas de servicios
- Probar con inventario real de lademo en `--check --diff`

---

## Verificación final

### Lint + Molecule (CI local)
```bash
yamllint roles/ && ansible-lint roles/la-compose/
cd roles/la-compose && molecule test
```

### Dry-run contra inventario real
```bash
ansible-playbook -i /data/la-toolkit/config/lademo/lademo-inventories/ \
  playbooks/config-gen.yml --limit docker_compose --check --diff -vv
docker compose -f /data/docker-compose/docker-compose.yml config
```

### Tests en máquinas reales: Jenkinsfile

El POC tiene un `Jenkinsfile` que orquesta tests end-to-end sobre 3 máquinas reales (`gbif-es-docker-cluster-2023-1/2/3`). Debe portarse a `la-docker-compose` con los ajustes necesarios.

Flujo del Jenkinsfile (parámetros: `FORCE_REDEPLOY`, `CLEAN_MACHINE`, `ONLY_CLEAN`):

```
1. Clean machines (paralelo en los 3 hosts)
   - docker compose down -v  (si /data/docker-compose existe)
   - Stop docker + containerd
   - Limpiar /data (preservar lost+found y var-lib-containerd)
   - Desinstalar docker-ce, apt-get remove

2. Update repos
   - git clone/pull ala-install (branch: docker-compose-poc → main)
   - git clone/pull generator-living-atlas

3. Decide redeploy (detecta cambios de SHA en ambos repos)

4. Regenerate inventories
   - npm install yo + generator-living-atlas
   - yo living-atlas --replay-dont-ask --force

5. Redeploy
   - ./ansiblew --alainstall=../../la-docker-compose docker_compose -n
```

Adaptaciones para `la-docker-compose`:
- `BRANCH_ALA` → rama de `la-docker-compose` (en vez de fork de ala-install)
- `ALA_GIT_URL` → URL del nuevo repo `la-docker-compose`
- El paso de redeploy llama a `la-docker-compose` en vez de `ala-install`
- Añadir stage de validación post-deploy: `docker compose ps`, check de Gatus healthcheck

