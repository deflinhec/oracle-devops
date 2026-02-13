# Oracle DevOps Stack

本專案使用 **Docker Swarm** 部署 Oracle 相關服務（MariaDB、Redis、MongoDB、Kafka、ClickHouse、應用服務等）。以下說明如何啟動整個 stack。

---

## 如何啟動

### 前置需求

- 已安裝 **Docker** 與 **Docker Compose**
- 需使用 **Docker Swarm 模式**（`docker swarm init`）

### 一、初始化 Swarm（若尚未初始化）

```bash
docker swarm init
```

### 二、單節點部署（開發／測試）

若只有一台機器，可將所有服務跑在同一節點上，需先給該節點加上 stack 所需的 label：

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
docker node update --label-add zone=zone-a           $NODE_ID   # 可選，供 API 分散部署用
```

### 三、準備設定檔

- **應用設定**：stack 會掛載 `./deploy/config.yaml` 為 config。若專案中沒有此檔，可先設定好 `IMAGE_REGISTRY`（見下方環境變數），再執行應用映像產生預設設定並寫入 `deploy/config.yaml`：

  ```bash
  docker run -it --rm ${IMAGE_REGISTRY}/oracle/app:latest deploy config --stdout > config.yaml
  ```

  或自行在 `deploy/` 下建立 `config.yaml`，或修改 stack 中對應的 config 來源。
- **環境變數**：可複製 `.env.example` 為 `.env`，並設定 `IMAGE_REGISTRY`（必填）及資料庫等變數（有預設值，可選）。

### 四、部署 Stack

```bash
# 使用 stack 檔部署，stack 名稱可自訂（例如 oracle）
docker stack deploy -c docker-compose.stack.yml oracle
```

### 五、查看服務狀態

```bash
# 列出 stack 內所有服務
docker stack services oracle

# 查看各服務的 task 與節點
docker stack ps oracle
```

### 六、停止與移除

```bash
# 移除整個 stack（會刪除 stack 內所有服務，volume 依設定保留）
docker stack rm oracle
```

---

## 多節點部署

在多台機器部署時，先在每台節點上加入 Swarm，再依角色為不同節點加上對應的 label（例如只在一台加 `role.db=master`，在另一台加 `role.cache=true`），然後在同一 swarm 上執行上述「準備設定檔」與「部署 Stack」步驟即可。各服務的節點約束可參考 `docker-compose.stack.yml` 中的 `deploy.placement.constraints`。

---

## 注意事項

- **環境變數**：本 stack 未使用 Docker Secrets，資料庫與應用相關設定皆透過 `.env` 與 `docker-compose.stack.yml` 的預設值提供；`IMAGE_REGISTRY` 無預設值，需在 `.env` 中設定。
- **Node labels**：若節點沒有對應 label，該服務的 task 會一直處於 Pending，可用 `docker stack ps oracle` 檢查。
- **Config 與 deploy 目錄**：若缺少 `./deploy/config.yaml`，部署時會報錯，請先建立檔案或調整 stack 中的 config 路徑。
