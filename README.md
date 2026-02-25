# Oracle DevOps Stack

本專案以 **Docker Swarm** 部署 Oracle 相關服務（MariaDB、Redis、MongoDB、Kafka、ClickHouse、應用服務等）。以下說明如何啟動整個 stack。

---

## 如何啟動

### 前置需求

- 已安裝 **Docker** 與 **Docker Compose**
- 需先啟用 **Docker Swarm 模式**（`docker swarm init`）

### 一、初始化 Swarm（若尚未初始化）

**1. 選定一台機器作為 Manager 節點，執行以下指令初始化 Swarm 叢集：**

  ```bash
  docker swarm init
  ```

**2. 於各 Worker 節點上執行 Manager 輸出的 join 指令，將節點加入叢集：**

  ```bash
  docker swarm join --token <token> <manager_ip>:2377
  ```

  <details>
  <summary>若未取得或遺失 join token，可於 Manager 節點重新取得</summary>

  ```bash
  docker swarm join-token worker
  # 輸出會顯示完整的 docker swarm join 指令，於 Worker 節點上執行即可
  ```
  </details>

### 二、設定節點 label

**1. 於 Manager 節點列出所有節點：**

```bash
docker node ls
```

**2. 依節點角色為各節點加上對應 label（請將下列 `$NODE*_ID` 替換為實際節點 ID）：**

```bash
# 範例節點與服務對應
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

**注意：** 同一節點可擁有多個 label（例如同時跑 API 與 Nginx）。各服務的 placement 約束請對照 [docker-compose.stack.yml](./docker-compose.stack.yml) 中的 `deploy.placement.constraints`。

<details>
<summary>單節點部署：僅有一台機器時，可將所有 label 加於同一節點</summary>

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

- **環境變數**：複製 [.env.example](./.env.example) 為 `.env`，並依需求設定資料庫等變數。環境變數擁有最高優先權，會覆蓋 compose/stack 與生成檔內的預設值。

- **應用設定**：stack 會掛載 `./deploy/config.yaml` 作為應用 config。若尚無此檔，可執行 `make config` 從映像產生預設設定（已有檔案時會詢問是否覆寫），生成時會優先帶入環境變數；執行前請先設定 `IMAGE_REGISTRY`（見下方環境變數）。亦可自行在 `deploy/` 下建立 `config.yaml`，或修改 stack 中對應的 config 來源。

  ```bash
  make config
  ```

### 四、建立靜態網頁掛載目錄

Nginx 會掛載主機的 `/var/www` 作為靜態資源目錄。凡具備 **`role.web=true`** label 的節點，須事先建立此目錄，否則 Nginx 容器無法啟動；此目錄後續由 **GitLab CI/CD** 部署靜態網頁。

```bash
# 在每個 web 節點上執行
sudo mkdir -p /var/www/
```

### 五、部署 Stack

部署採 **分 stack** 方式，須指定 target：`make deploy-<target>`。可用 target：**app**（主服務）、**elk**、**util**、**monitor**。執行 `make deploy` 會印出用法說明。

- **`make deploy-app`**：部署主 stack（MariaDB、Redis、MongoDB、Kafka、應用服務等），會先確保 Registry 已登入，並依 `.env` 與 Makefile 變數 `STACK_NAME`（預設 `oracle`）、`IMAGE_REGISTRY`、`VERSION` 部署 `docker-compose.stack.yml`。
- **`make deploy-elk`** / **`make deploy-util`** / **`make deploy-monitor`**：分別部署對應的 compose 檔（如 `docker-compose.elk.stack.yml`），stack 名稱即 target（elk、util、monitor）。

```bash
make deploy-app
# 或：make deploy-elk、make deploy-util、make deploy-monitor
```

### 六、查看服務狀態

- **`docker stack services <stack_name>`**：列出該 stack 內所有服務及其副本數、映像、port 等。
  ```bash
  docker stack services oracle
  ```

- **`docker stack ps <stack_name>`**：列出各服務的 task、所在節點與狀態，可檢查是否有 task 卡在 Pending 或 Failed。
  ```bash
  docker stack ps oracle
  ```

### 七、停止與移除

移除同樣須指定 target：`make remove-<target>`，對應 **app**、**elk**、**util**、**monitor**。執行 `make remove` 會印出用法。會呼叫 `docker stack rm <stack_name>` 移除該 stack 及所有服務；Volume 依 stack 定義保留，不會自動刪除。

```bash
make remove-app
# 或：make remove-elk、make remove-util、make remove-monitor
```

---

## 注意事項

- **環境變數**：本 stack 未使用 Docker Secrets，資料庫與應用設定由 `.env` 及 `docker-compose.stack.yml` 的預設值提供；`STACK_NAME`、`IMAGE_REGISTRY`、`VERSION` 等可在 `.env` 中覆寫 Makefile 預設值。
- **Node labels**：節點若缺少對應 label，該服務的 task 會持續處於 Pending，可用 `docker stack ps <stack_name>` 檢查。
- **應用設定檔**：部署前須具備 `./deploy/config.yaml`，可執行 `make config` 從映像產生；缺少時部署會報錯。
- **Web 節點 `/var/www`**：具備 `role.web=true` 的節點須手動建立 `/var/www` 目錄，靜態資源由 GitLab CI/CD 部署。
