########################################################
# Environment Variables
########################################################

# 載入 .env 檔案
-include .env

# 映像檔 reference
VERSION ?= develop

# Stack 名稱
STACK_NAME ?= oracle

# 映像檔 registry
IMAGE_REGISTRY ?= 480126395291.dkr.ecr.ap-east-1.amazonaws.com/igaming/

########################################################
# Stack Management
########################################################

.PHONY: _ensure-registry
# 確保 registry 已登入
_ensure-registry:
	aws ecr get-login-password --region ap-east-1 | \
		docker login --username AWS --password-stdin $(IMAGE_REGISTRY)

.PHONY: deploy
# 部署 stack（IMAGE_REGISTRY、VERSION 會傳入 compose 供 image 使用）
deploy: _ensure-registry
	IMAGE_REGISTRY="$(IMAGE_REGISTRY)" VERSION="$(VERSION)" \
	docker stack deploy -c docker-compose.stack.yml $(STACK_NAME) --with-registry-auth

.PHONY: deploy-elk
# 部署 elk stack
deploy-elk:
	STACK_NAME="$(STACK_NAME)" \
	docker stack deploy -c docker-compose.elk.stack.yml elk

.PHONY: remove
# 移除 stack
remove: remove-elk
	docker stack rm $(STACK_NAME)

.PHONY: remove-elk
# 移除 elk stack
remove-elk:
	docker stack rm elk

########################################################
# Config
########################################################

.PHONY: config
# 部署應用設定：從映像檔中部署應用設定到本地 deploy/config.yaml（若已存在會先詢問，同意後改名为 config.<datetime>.yaml）
config: _ensure-registry
	mkdir -p ./deploy
	@if [ -f ./deploy/config.yaml ]; then \
		printf 'deploy/config.yaml 已存在，是否覆寫？ [y/N] '; \
		read -r ans; \
		case "$$ans" in [yY]|[yY][eE][sS]) ;; *) echo '已取消'; exit 0; esac; \
		ts=$$(date +%Y%m%d%H%M%S); \
		mv ./deploy/config.yaml ./deploy/config.$$ts.yaml && echo "已將原檔移至 deploy/config.$$ts.yaml"; \
	fi; \
	docker run -it --rm \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		config deploy --stdout > ./deploy/config.yaml

.PHONY: _ensure-config
# 確保 config 存在
_ensure-config: _ensure-registry
	@if [ ! -f ./deploy/config.yaml ]; then \
		echo "==> 建立 config"; \
		mkdir -p ./deploy; \
		docker run -it --rm \
			$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
			config deploy --stdout > ./deploy/config.yaml; \
		echo "==> config 建立完成"; \
	else \
		echo "==> config 已存在"; \
	fi;

########################################################
# Migrate
########################################################

.PHONY: migrate
# 遷移資料庫：從本地 deploy/config.yaml 遷移資料庫
migrate: _ensure-config
	docker run -it --rm \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		migrate up

########################################################
# Stack Setup
########################################################

.PHONY: setup
# 設定 CDC 與 Kafka topic
setup: migrate setup-cdc setup-kafka

.PHONY: setup-cdc
# 設定 CDC
setup-cdc: _ensure-config 
	docker run -it --rm \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		cdc setup db --user root --password $(DB_ROOT_PASSWORD)
	docker run -it --rm \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		cdc setup debezium

.PHONY: setup-kafka
# 設定 Kafka topic
setup-kafka: _ensure-config
	docker run -it --rm \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		kafka setup

########################################################
# 更新 config
########################################################

.PHONY: config-update
# 更新 config
config-update: config-update-nginx config-update-oracle config-update-mariadb

.PHONY: config-update-nginx
# 更新 nginx 設定：建立帶時間戳的 config，移除符合的既有 config，再掛上新 config
config-update-nginx:
	@CONFIG_PATTERN="$(STACK_NAME)_nginx_config"; \
	CONFIG_NEW="$${CONFIG_PATTERN}_$$(date +%Y%m%d%H%M%S)"; \
	echo "==> 建立 config $$CONFIG_NEW（來源：./config/nginx/oracle.conf）"; \
	docker config create "$$CONFIG_NEW" ./config/nginx/oracle.conf; \
	RM_ARGS=""; \
	for c in $$(docker service inspect $(STACK_NAME)_nginx \
	  --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}} {{end}}' \
	  2>/dev/null | tr ' ' '\n' | grep "^$$CONFIG_PATTERN" || true); do \
	  [ -n "$$c" ] && { echo "    自 $(STACK_NAME)_nginx 移除 config $$c"; RM_ARGS="$$RM_ARGS --config-rm $$c"; }; \
	done; \
	echo "==> 更新服務 $(STACK_NAME)_nginx，掛上 config $$CONFIG_NEW"; \
	eval docker service update $$RM_ARGS \
	  --config-add source="$$CONFIG_NEW",target=/etc/nginx/sites-enabled/default \
	  $(STACK_NAME)_nginx; \
	echo "==> nginx 設定更新完成"

.PHONY: config-update-oracle
# 更新 Oracle 應用設定：建立帶時間戳的 config，更新 api / consumer / scheduler
config-update-oracle:
	@CONFIG_PATTERN="$(STACK_NAME)_oracle_config"; \
	CONFIG_NEW="$${CONFIG_PATTERN}_$$(date +%Y%m%d%H%M%S)"; \
	echo "==> 建立 config $$CONFIG_NEW（來源：./deploy/config.yaml）"; \
	docker config create "$$CONFIG_NEW" ./deploy/config.yaml; \
	for svc in api consumer scheduler; do \
	  RM_ARGS=""; \
	  for c in $$(docker service inspect $(STACK_NAME)_$$svc \
	    --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}} {{end}}' \
	    2>/dev/null | tr ' ' '\n' | grep "^$$CONFIG_PATTERN" || true); do \
	    [ -n "$$c" ] && { echo "    自 $(STACK_NAME)_$$svc 移除 config $$c"; RM_ARGS="$$RM_ARGS --config-rm $$c"; }; \
	  done; \
	  echo "==> 更新服務 $(STACK_NAME)_$$svc，掛上 config $$CONFIG_NEW"; \
	  eval docker service update $$RM_ARGS \
	    --config-add source="$$CONFIG_NEW",target=/app/deploy/config.yaml,mode=0444 \
	    $(STACK_NAME)_$$svc; \
	done; \
	echo "==> Oracle 設定更新完成"

.PHONY: config-update-mariadb
# 更新 MariaDB 設定：建立帶時間戳的 config，更新 mariadb
config-update-mariadb:
	@CONFIG_PATTERN="$(STACK_NAME)_mariadb_config"; \
	CONFIG_NEW="$${CONFIG_PATTERN}_$$(date +%Y%m%d%H%M%S)"; \
	echo "==> 建立 config $$CONFIG_NEW（來源：./config/mariadb/mariadb.cnf）"; \
	docker config create "$$CONFIG_NEW" ./config/mariadb/mariadb.cnf; \
	RM_ARGS=""; \
	for c in $$(docker service inspect $(STACK_NAME)_mariadb \
	  --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}} {{end}}' \
	  2>/dev/null | tr ' ' '\n' | grep "^$$CONFIG_PATTERN" || true); do \
	  [ -n "$$c" ] && { echo "    自 $(STACK_NAME)_mariadb 移除 config $$c"; RM_ARGS="$$RM_ARGS --config-rm $$c"; }; \
	done; \
	echo "==> 更新服務 $(STACK_NAME)_mariadb，掛上 config $$CONFIG_NEW"; \
	eval docker service update $$RM_ARGS \
	  --config-add source="$$CONFIG_NEW",target=/etc/mysql/conf.d/mariadb.cnf,mode=0444 \
	  $(STACK_NAME)_mariadb; \
	echo "==> MariaDB 設定更新完成"

########################################################
# 更新 Elasticsearch/Logstash/Filebeat Config
########################################################

.PHONY: config-update-elk
# 更新 elk 設定：更新 filebeat / logstash
config-update-elk: config-update-filebeat config-update-logstash

.PHONY: config-update-filebeat
# 更新 filebeat 設定：建立帶時間戳的 config，更新 filebeat
config-update-filebeat:
	@CONFIG_PATTERN="elk_filebeat_config"; \
	CONFIG_NEW="$${CONFIG_PATTERN}_$$(date +%Y%m%d%H%M%S)"; \
	echo "==> 建立 config $$CONFIG_NEW（來源：./config/filebeat/filebeat.yml）"; \
	docker config create "$$CONFIG_NEW" ./config/filebeat/filebeat.yml; \
	RM_ARGS=""; \
	for c in $$(docker service inspect elk_filebeat \
	  --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}} {{end}}' \
	  2>/dev/null | tr ' ' '\n' | grep "^$$CONFIG_PATTERN" || true); do \
		[ -n "$$c" ] && { echo "    自 elk_filebeat 移除 config $$c"; RM_ARGS="$$RM_ARGS --config-rm $$c"; }; \
	done; \
	echo "==> 更新服務 elk_filebeat，掛上 config $$CONFIG_NEW"; \
	eval docker service update $$RM_ARGS \
	  --config-add source="$$CONFIG_NEW",target=/usr/share/filebeat/filebeat.yml,mode=0444 \
	  elk_filebeat; \
	echo "==> Filebeat 設定更新完成"

.PHONY: config-update-logstash
# 更新 logstash 設定：建立帶時間戳的 config，更新 logstash
config-update-logstash:
	@CONFIG_PATTERN="elk_logstash_config"; \
	CONFIG_NEW="$${CONFIG_PATTERN}_$$(date +%Y%m%d%H%M%S)"; \
	echo "==> 建立 config $$CONFIG_NEW（來源：./config/logstash/logstash.conf）"; \
	docker config create "$$CONFIG_NEW" ./config/logstash/logstash.conf; \
	RM_ARGS=""; \
	for c in $$(docker service inspect elk_logstash \
	  --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}} {{end}}' \
	  2>/dev/null | tr ' ' '\n' | grep "^$$CONFIG_PATTERN" || true); do \
		[ -n "$$c" ] && { echo "    自 elk_logstash 移除 config $$c"; RM_ARGS="$$RM_ARGS --config-rm $$c"; }; \
	done; \
	echo "==> 更新服務 elk_logstash，掛上 config $$CONFIG_NEW"; \
	eval docker service update $$RM_ARGS \
	  --config-add source="$$CONFIG_NEW",target=/usr/share/logstash/pipeline/logstash.conf,mode=0444 \
	  elk_logstash; \
	echo "==> Logstash 設定更新完成"

########################################################
# Image Update
########################################################

.PHONY: image-update
# 更新 image
image-update: _ensure-registry
	docker service update \
			--image $(IMAGE_REGISTRY)oracle/app:$(VERSION) \
			--with-registry-auth \
			$(STACK_NAME)_consumer; \
	docker service update \
			--image $(IMAGE_REGISTRY)oracle/app:$(VERSION) \
			--with-registry-auth \
			$(STACK_NAME)_scheduler; \
	docker service update \
			--image $(IMAGE_REGISTRY)oracle/app:$(VERSION) \
			--update-order start-first \
			--update-parallelism 1 \
			--update-delay 10s \
			--with-registry-auth \
			$(STACK_NAME)_api; \

########################################################
# Node Management
########################################################

.PHONY: node-list
# 列出所有節點的 label
node-list:
	docker node ls -q | xargs -I {} docker node inspect {} \
		--format '{{ .Description.Hostname }} -> {{ .Spec.Labels }}'

.PHONY: node-label-add
# 為節點加上 label
node-label-add:
	docker node update --label-add $1 $2

.PHONY: node-label-remove
# 為節點移除 label
node-label-remove:
	docker node update --label-rm $1 $2

########################################################
# Stack Management
########################################################

.PHONY: stack-services
# 列出 stack 內所有服務
stack-services:
	docker stack services $(STACK_NAME)

.PHONY: stack-tasks
# 列出 stack 內所有 task
stack-tasks:
	docker stack ps $(STACK_NAME)

########################################################
# Shell
########################################################
.PHONY: shell
# 建立 shell 進入 stack 內部
shell: _ensure-registry
	docker run -it --rm \
		--user root \
		--network $(STACK_NAME)_backend_network \
		--entrypoint "/bin/sh" \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		-c "apk add curl bash vim \
			&& exec bash"