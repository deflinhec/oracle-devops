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

export

########################################################
# Help
########################################################
.PHONY: help
help: ## 顯示此說明訊息
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-26s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

########################################################
# Registry Management
########################################################

.PHONY: _ensure-registry
_ensure-registry: # 確保 registry 已登入（ECR）
	aws ecr get-login-password --region ap-east-1 | \
		docker login --username AWS --password-stdin $(IMAGE_REGISTRY)

########################################################
# Stack Management
########################################################

.PHONY: deploy deploy-% deploy-app deploy-elk deploy-util deploy-monitor
deploy: deploy-app deploy-elk deploy-util deploy-monitor ## 部署全部 stack（app, elk, util, monitor）

deploy-app: _ensure-registry ## 部署 app stack（$(STACK_NAME)）
	@echo "Deploying app stack..."
	@docker stack deploy -c docker-compose.stack.yml $(STACK_NAME) --with-registry-auth

deploy-elk: ## 部署 elk stack
	@echo "Deploying elk stack..."
	@docker stack deploy -c docker-compose.elk.stack.yml elk

deploy-util: ## 部署 util stack
	@echo "Deploying util stack..."
	@docker stack deploy -c docker-compose.util.stack.yml util

deploy-monitor: ## 部署 monitor stack
	@echo "Deploying monitor stack..."
	@docker stack deploy -c docker-compose.monitor.stack.yml monitor

deploy-%: ## 部署指定 stack（make deploy-app | deploy-elk | deploy-util | deploy-monitor）
	@case "$*" in \
		app|elk|util|monitor) $(MAKE) deploy-$* ;; \
		*) echo "Invalid stack: $*. Available: app, elk, util, monitor"; exit 1 ;; \
	esac

.PHONY: remove remove-% remove-app remove-elk remove-util remove-monitor
remove: remove-monitor remove-util remove-elk remove-app ## 移除全部 stack（reverse order: monitor, util, elk, app）

remove-app: ## 移除 app stack（$(STACK_NAME)）
	@echo "Removing app stack..."
	@docker stack rm $(STACK_NAME)

remove-elk: ## 移除 elk stack
	@echo "Removing elk stack..."
	@docker stack rm elk

remove-util: ## 移除 util stack
	@echo "Removing util stack..."
	@docker stack rm util

remove-monitor: ## 移除 monitor stack
	@echo "Removing monitor stack..."
	@docker stack rm monitor

remove-%: ## 移除指定 stack
	@case "$*" in \
		app|elk|util|monitor) $(MAKE) remove-$* ;; \
		*) echo "Invalid stack: $*. Available: app, elk, util, monitor"; exit 1 ;; \
	esac

########################################################
# Config
########################################################

.PHONY: config
config: _ensure-registry ## 部署應用設定至 deploy/config.yaml（從映像檔取得，若已存在會詢問覆寫）
	mkdir -p ./deploy
	@if [ -f ./deploy/config.yaml ]; then \
		printf 'deploy/config.yaml 已存在，是否覆寫？ [y/N] '; \
		read -r ans; \
		case "$$ans" in [yY]|[yY][eE][sS]) ;; *) echo '已取消'; exit 0; esac; \
		ts=$$(date +%Y%m%d%H%M%S); \
		mv ./deploy/config.yaml ./deploy/config.$$ts.yaml && echo "已將原檔移至 deploy/config.$$ts.yaml"; \
	fi; \
	docker run -it --rm --env-file .env \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		config deploy --stdout > ./deploy/config.yaml

.PHONY: _ensure-config
_ensure-config: _ensure-registry # 確保 deploy/config.yaml 存在（內部用）
	@if [ ! -f ./deploy/config.yaml ]; then \
		echo "==> 建立 config"; \
		mkdir -p ./deploy; \
		docker run -it --rm --env-file .env \
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
migrate: _ensure-config ## 從 deploy/config.yaml 遷移資料庫
	docker run -it --rm --env-file .env \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		migrate up

########################################################
# Stack Setup
########################################################

.PHONY: setup
setup: migrate setup-cdc setup-kafka ## 執行 migrate、CDC 與 Kafka 設定

.PHONY: setup-cdc
setup-cdc: _ensure-config ## 設定 CDC（DB + Debezium） 
	docker run -it --rm --env-file .env \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		cdc setup db --user root --password $(DB_ROOT_PASSWORD)
	docker run -it --rm --env-file .env \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		cdc setup debezium

.PHONY: setup-kafka
setup-kafka: _ensure-config ## 設定 Kafka topic
	docker run -it --rm --env-file .env \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		kafka setup

########################################################
# 更新 config
########################################################

.PHONY: config-update config-update-%
config-update: config-update-app config-update-nginx config-update-db ## 更新 nginx、應用、DB 的 Docker config

config-update-%: ## 更新指定 config（make config-update-nginx | app | db | elk | filebeat | logstash）
	@case "$*" in \
		nginx|app|db|elk|filebeat|logstash) $(MAKE) config-update-$* ;; \
		*) echo "Invalid config-update target: $*. Available: nginx, app, db, elk, filebeat, logstash"; exit 1 ;; \
	esac

.PHONY: config-update-nginx
config-update-nginx: ## 更新 nginx 設定（建立帶時間戳的 config 並掛到服務）
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

.PHONY: config-update-app
config-update-app: ## 更新 Oracle 應用設定（api / consumer / scheduler）
	@CONFIG_PATTERN="$(STACK_NAME)_app_config"; \
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
	echo "==> 應用設定更新完成"

.PHONY: config-update-db
config-update-db: ## 更新 MariaDB 設定（Docker config）
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
config-update-elk: config-update-filebeat config-update-logstash ## 更新 ELK 設定（filebeat + logstash）

.PHONY: config-update-filebeat
config-update-filebeat: ## 更新 Filebeat 設定（Docker config）
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
config-update-logstash: ## 更新 Logstash 設定（Docker config）
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
# Image Management
########################################################

.PHONY: image-update
image-update: _ensure-registry ## 更新 stack 內 app 服務的 image 版本（consumer, scheduler, api）
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

.PHONY: image-version
image-version: ## 顯示 app image 版本
	docker run -it --rm --env-file .env \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		--version;

########################################################
# Node Management
########################################################

.PHONY: node-list
node-list: ## 列出所有節點的 label
	docker node ls -q | xargs -I {} docker node inspect {} \
		--format '{{ .Description.Hostname }} -> {{ .Spec.Labels }}'

.PHONY: node-label-add
node-label-add: ## 為節點加上 label（用法：make node-label-add key=value NODE_ID）
	docker node update --label-add $1 $2

.PHONY: node-label-remove
node-label-remove: ## 為節點移除 label（用法：make node-label-remove key NODE_ID）
	docker node update --label-rm $1 $2

########################################################
# Stack Management
########################################################

.PHONY: stack-services
stack-services: ## 列出 stack 內所有服務
	docker stack services $(STACK_NAME)

.PHONY: stack-tasks
stack-tasks: ## 列出 stack 內所有 task
	docker stack ps $(STACK_NAME)

########################################################
# Shell
########################################################
.PHONY: shell
shell: _ensure-registry ## 建立 shell 進入 stack 網路內（掛載 deploy/config.yaml，含 curl/bash/vim）
	docker run -it --rm --env-file .env \
		--user root \
		--entrypoint "/bin/sh" \
		--network $(STACK_NAME)_backend_network \
		-v $(PWD)/deploy/config.yaml:/app/deploy/config.yaml \
		$(IMAGE_REGISTRY)oracle/app:$(VERSION) \
		-c "apk add curl bash vim \
			&& exec bash"