STACK_NAME ?= oracle

# nginx 設定檔名稱前綴（更新時會移除符合的既有 config）
NGINX_CONFIG_PATTERN ?= oracle_nginx_config

# Oracle 應用設定檔名稱前綴（供 api、consumer、scheduler 使用）
ORACLE_CONFIG_PATTERN ?= oracle_oracle_config

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
# 部署應用設定：從映像檔中部署應用設定到本地 deploy/config.yaml
config:
	mkdir -p ./deploy
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
	echo "==> 建立 config $$CONFIG_NEW（來源：./config.yaml）"; \
	docker config create "$$CONFIG_NEW" ./config.yaml; \
	for svc in api consumer scheduler; do \
	  RM_ARGS=""; \
	  for c in $$(docker service inspect $(STACK_NAME)_$$svc --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{.ConfigName}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep '^$(ORACLE_CONFIG_PATTERN)' || true); do \
	    [ -n "$$c" ] && { echo "    自 $(STACK_NAME)_$$svc 移除 config $$c"; RM_ARGS="$$RM_ARGS --config-rm $$c"; }; \
	  done; \
	  echo "==> 更新服務 $(STACK_NAME)_$$svc，掛上 config $$CONFIG_NEW"; \
	  eval docker service update $$RM_ARGS --config-add source="$$CONFIG_NEW",target=/app/deploy/config.yaml,mode=0444 $(STACK_NAME)_$$svc; \
	done; \
	echo "==> Oracle 設定更新完成"

.PHONY: node-labels
# 列出所有節點的 label
node-labels:
	docker node ls -q | xargs -I {} docker node inspect {} --format '{{ .Description.Hostname }} -> {{ .Spec.Labels }}'
