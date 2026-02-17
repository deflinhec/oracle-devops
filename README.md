# Oracle DevOps Stack

本專案使用 **Docker Swarm** 部署 Oracle 相關服務（MariaDB、Redis、MongoDB、Kafka、ClickHouse、應用服務等）。以下說明如何啟動整個 stack。

---

## 如何啟動

### 前置需求

- 已安裝 **Docker** 與 **Docker Compose**
- 需使用 **Docker Swarm 模式**（`docker swarm init`）

### 一、初始化 Swarm（若尚未初始化）

**1. 選定一台機器作為 Manager 節點，運行以下指令初始化 Docker Swarm 集群：**

  ```bash
  docker swarm init
  ```

**2. 將上述步驟提供的指令於各節點上運行，將所有節點添加至 Docker Swarm 集群：**


  ```bash
  docker swarm join --token <token> <manager_ip>:2377
  ```

  <details>
  <summary>若未取得或遺失 join token，可於 Manager 節點重新取得</summary>

  ```bash
  docker swarm join-token worker
  # 輸出會顯示完整的 docker swarm join --token <token> <manager_ip>:2377 指令
  # 將該指令在 Worker 節點上執行即可
  ```
  </details>

### 二、設置節點 label 標籤

**1. 在 Manager 節點列出所有節點並為各節點加上 label**

```bash
docker node ls
```

**2. 依節點角色為不同節點加上對應的 label。**

```bash
# 範例節點與服務對應（依實際節點 ID 替換 <node_id>）
#
#  node1            node2            node3            node4
# ┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
# │ MariaDB │     │ kafka01 │     │ kafka02 │     │ kafka03 │
# │ Redis   │     │ API     │     │Consumer │     │Scheduler│
# │ MongoDB │     └─────────┘     └─────────┘     │ Nginx   │
# │ClickHous│                                     └─────────┘
# │   CDC   │                                     
# └─────────┘

# DB 節點（MariaDB）
docker node update --label-add role.db=master $NODE1_ID

# Cache 節點（Redis）
docker node update --label-add role.cache=true $NODE1_ID

# MongoDB 節點
docker node update --label-add role.mdb=true $NODE1_ID

# ClickHouse 節點
docker node update --label-add role.olap=true $NODE1_ID

# Kafka 節點（三台各綁定一個 broker）
docker node update --label-add role.kafka=1 $NODE2_ID
docker node update --label-add role.kafka=2 $NODE3_ID
docker node update --label-add role.kafka=3 $NODE4_ID

# Kafka Connect 節點
docker node update --label-add role.cdc=true $NODE1_ID

# Nginx 節點（可多台，mode: global 會在各有 label 的節點都跑）
docker node update --label-add role.web=true $NODE4_ID

# API / Consumer / Scheduler 節點（可分散到不同節點）
docker node update --label-add role.api=true $NODE2_ID
docker node update --label-add role.consumer=true $NODE3_ID
docker node update --label-add role.scheduler=true $NODE4_ID
```

**注意：** 每個節點可加多個 label（例如同一台跑 API + Nginx）。各服務的 placement 約束請對照 [docker-compose.stack.yaml](./docker-compose.stack.yaml) 中的 `deploy.placement.constraints`。

<details>
<summary>若只有一台機器，可將所有服務跑在同一節點上</summary>

```bash
# 取得本節點 ID
NODE_ID=$(docker node ls -q)

# 加上 stack 所需的節點標籤（單節點時全加在同一節點）
docker node update --label-add role.db=master        $NODE_ID
docker node update --label-add role.cache=true       $NODE_ID
docker node update --label-add role.mdb=true         $NODE_ID
docker node update --label-add role.kafka=1          $NODE_ID
docker node update --label-add role.kafka=2          $NODE_ID
docker node update --label-add role.kafka=3          $NODE_ID
docker node update --label-add role.cdc=true         $NODE_ID
docker node update --label-add role.olap=true        $NODE_ID
docker node update --label-add role.web=true         $NODE_ID
docker node update --label-add role.api=true         $NODE_ID
docker node update --label-add role.consumer=true    $NODE_ID
docker node update --label-add role.scheduler=true   $NODE_ID
```

</details>

### 三、準備設定檔

- **應用設定**：stack 會掛載 `./deploy/config.yaml` 為 config。若專案中沒有此檔，可執行 `make config`（會從映像產生預設設定，若已有檔案會詢問是否覆寫）：

  ```bash
  make config
  ```

  或自行在 `deploy/` 下建立 `config.yaml`，或修改 stack 中對應的 config 來源。執行前請先設定 `IMAGE_REGISTRY`（見下方環境變數）。

- **環境變數**：複製 `.env.example` 為 `.env`，並設定資料庫等變數（有預設值，可選）。

### 四、建立靜態網頁掛載目錄

Nginx 會掛載主機的 `/var/www` 作為靜態資源目錄。在**有 `role.web=true` label 的節點**上，需人工建立此目錄，否則 Nginx 容器啟動會失敗。此目錄後續會由 **GitLab CI/CD** 進行靜態網頁部署。

```bash
# 在每個 web 節點上執行
sudo mkdir -p /var/www/
```

### 五、部署 Stack

執行 `make deploy` 會依 `.env` 與 Makefile 的 `STACK_NAME`（預設 `oracle`）、`IMAGE_REGISTRY`、`VERSION` 部署整個 stack。

```bash
make deploy
```

### 六、查看服務狀態

- `docker stack services <stack_name>`：列出該 stack 內所有服務與其 replicas、映像、port 等。
  ```bash
  # 列出 stack 內所有服務
  docker stack services oracle
  ```

- `docker stack ps <stack_name>`：列出各服務的 task 與所在節點、狀態，可檢查是否有 task 卡在 Pending 或 Failed。

  ```bash
  # 查看各服務的 task 與節點分佈
  docker stack ps oracle
  ```

### 七、停止與移除

執行 `make remove` 會呼叫 `docker stack rm`，移除整個 stack 及其所有服務。Volume 依 stack 定義保留，不會自動刪除。

```bash
make remove
```

---

## 注意事項

- **環境變數**：本 stack 未使用 Docker Secrets，資料庫與應用設定透過 `.env` 與 `docker-compose.stack.yml` 的預設值提供。`STACK_NAME`、`IMAGE_REGISTRY`、`VERSION` 等有 Makefile 預設值，可於 `.env` 覆寫。
- **Node labels**：若節點沒有對應 label，該服務的 task 會一直處於 Pending，可用 `docker stack ps <stack_name>` 檢查。
- **Config 與 deploy 目錄**：部署前需有 `./deploy/config.yaml`，可執行 `make config` 從映像產生；若缺少則會報錯。
- **Web 節點 `/var/www`**：有 `role.web=true` 的節點須人工建立 `/var/www` 目錄，靜態資源後續由 GitLab CI/CD 部署。
