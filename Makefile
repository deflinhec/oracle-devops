########################################################
# Environment Variables
########################################################

# 載入 .env 檔案
-include .env

# Stack 名稱
STACK_NAME ?= oracle

# MariaDB 設定檔名稱前綴（更新時會移除符合的既有 config）
MARIADB_CONFIG_PATTERN ?= $(STACK_NAME)_mariadb_config

# nginx 設定檔名稱前綴（更新時會移除符合的既有 config）
NGINX_CONFIG_PATTERN ?= $(STACK_NAME)_nginx_config

# Oracle 應用設定檔名稱前綴（供 api、consumer、scheduler 使用）
ORACLE_CONFIG_PATTERN ?= $(STACK_NAME)_oracle_config

# 映像檔 registry
IMAGE_REGISTRY ?= 480126395291.dkr.ecr.ap-east-1.amazonaws.com/igaming/

.PHONY: deploy
# 部署 stack
deploy:
	docker stack deploy -c docker-compose.stack.yml $(STACK_NAME) --with-registry-auth

.PHONY: remove
# 移除 stack
remove:
	docker stack rm $(STACK_NAME)

.PHONY: config
# 部署應用設定：從映像檔中部署應用設定到本地 deploy/config.yaml（若已存在會先詢問，同意後改名为 config.<datetime>.yaml）
config:
	mkdir -p ./deploy
	@if [ -f ./deploy/config.yaml ]; then \
		printf 'deploy/config.yaml 已存在，是否覆寫？ [y/N] '; \
		read -r ans; \
		case "$$ans" in [yY]|[yY][eE][sS]) ;; *) echo '已取消'; exit 0; esac; \
		ts=$$(date +%Y%m%d%H%M%S); \
		mv ./deploy/config.yaml ./deploy/config.$$ts.yaml && echo "已將原檔移至 deploy/config.$$ts.yaml"; \
	fi; \
	docker run -it --rm \
		$(IMAGE_REGISTRY)oracle/app:develop \
		config deploy --stdout > ./deploy/config.yaml

.PHONY: migrate
# 遷移資料庫：從本地 deploy/config.yaml 遷移資料庫
migrate:
	docker run -it --rm \
		--network $(STACK_NAME)_oracle-network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:develop \
		migrate up

.PHONY: node-labels
# 列出所有節點的 label
node-labels:
	docker node ls -q | xargs -I {} docker node inspect {} --format '{{ .Description.Hostname }} -> {{ .Spec.Labels }}'

########################################################
# Stack Setup
########################################################

.PHONY: setup
# 設定 CDC 與 Kafka topic
setup: _ensure-config migrate setup-cdc setup-kafka

.PHONY: _ensure-config
# 確保 config 存在
_ensure-config:
	@if [ ! -f ./deploy/config.yaml ]; then \
		echo "==> 建立 config"; \
		mkdir -p ./deploy; \
		docker run -it --rm \
			$(IMAGE_REGISTRY)oracle/app:develop \
			config deploy --stdout > ./deploy/config.yaml; \
		echo "==> config 建立完成"; \
	else \
		echo "==> config 已存在"; \
	fi;

.PHONY: setup-cdc
# 設定 CDC
setup-cdc:
	docker run -it --rm \
		--network $(STACK_NAME)_oracle-network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:develop \
		cdc setup db --user root --password $(DB_ROOT_PASSWORD)
	docker run -it --rm \
		--network $(STACK_NAME)_oracle-network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:develop \
		cdc setup debezium

.PHONY: setup-kafka
# 設定 Kafka topic
setup-kafka:
	docker run -it --rm \
		--network $(STACK_NAME)_oracle-network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:develop \
		kafka setup

########################################################
# 更新 config
########################################################

.PHONY: config-update
# 更新 config
config-update: config nginx-config-update oracle-config-update

.PHONY: nginx-config-update
# 更新 nginx 設定：建立帶時間戳的 config，移除符合的既有 config，再掛上新 config
nginx-config-update:
	@CONFIG_NEW="$(NGINX_CONFIG_PATTERN)_$$(date +%Y%m%d%H%M%S)"; \
	echo "==> 建立 config $$CONFIG_NEW（來源：./config/nginx/oracle.conf）"; \
	docker config create "$$CONFIG_NEW" ./config/nginx/oracle.conf; \
	RM_ARGS=""; \
	for c in $$(docker service inspect $(STACK_NAME)_nginx --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep '^$(NGINX_CONFIG_PATTERN)' || true); do \
	  [ -n "$$c" ] && { echo "    自 $(STACK_NAME)_nginx 移除 config $$c"; RM_ARGS="$$RM_ARGS --config-rm $$c"; }; \
	done; \
	echo "==> 更新服務 $(STACK_NAME)_nginx，掛上 config $$CONFIG_NEW"; \
	eval docker service update $$RM_ARGS --config-add source="$$CONFIG_NEW",target=/etc/nginx/sites-enabled/default $(STACK_NAME)_nginx; \
	echo "==> nginx 設定更新完成"

.PHONY: oracle-config-update
# 更新 Oracle 應用設定：建立帶時間戳的 config，更新 api / consumer / scheduler
oracle-config-update:
	@CONFIG_NEW="$(ORACLE_CONFIG_PATTERN)_$$(date +%Y%m%d%H%M%S)"; \
	echo "==> 建立 config $$CONFIG_NEW（來源：./deploy/config.yaml）"; \
	docker config create "$$CONFIG_NEW" ./deploy/config.yaml; \
	for svc in api consumer scheduler; do \
	  RM_ARGS=""; \
	  for c in $$(docker service inspect $(STACK_NAME)_$$svc --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep '^$(ORACLE_CONFIG_PATTERN)' || true); do \
	    [ -n "$$c" ] && { echo "    自 $(STACK_NAME)_$$svc 移除 config $$c"; RM_ARGS="$$RM_ARGS --config-rm $$c"; }; \
	  done; \
	  echo "==> 更新服務 $(STACK_NAME)_$$svc，掛上 config $$CONFIG_NEW"; \
	  eval docker service update $$RM_ARGS --config-add source="$$CONFIG_NEW",target=/app/deploy/config.yaml,mode=0444 $(STACK_NAME)_$$svc; \
	done; \
	echo "==> Oracle 設定更新完成"

.PHONY: mariadb-config-update
# 更新 MariaDB 設定：建立帶時間戳的 config，更新 mariadb
mariadb-config-update:
	@CONFIG_NEW="$(MARIADB_CONFIG_PATTERN)_$$(date +%Y%m%d%H%M%S)"; \
	echo "==> 建立 config $$CONFIG_NEW（來源：./config/mariadb/mariadb.cnf）"; \
	docker config create "$$CONFIG_NEW" ./config/mariadb/mariadb.cnf; \
	RM_ARGS=""; \
	for c in $$(docker service inspect $(STACK_NAME)_mariadb --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep '^$(MARIADB_CONFIG_PATTERN)' || true); do \
	  [ -n "$$c" ] && { echo "    自 $(STACK_NAME)_mariadb 移除 config $$c"; RM_ARGS="$$RM_ARGS --config-rm $$c"; }; \
	done; \
	echo "==> 更新服務 $(STACK_NAME)_mariadb，掛上 config $$CONFIG_NEW"; \
	eval docker service update $$RM_ARGS --config-add source="$$CONFIG_NEW",target=/etc/mysql/conf.d/mariadb.cnf,mode=0444 $(STACK_NAME)_mariadb; \
	echo "==> MariaDB 設定更新完成"

