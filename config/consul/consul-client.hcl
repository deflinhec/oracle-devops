datacenter = "dc1"
data_dir   = "/consul/data"
log_level  = "INFO"

server = false

# 綁定本機私網 IP（不依賴介面名稱，適用各節點）
bind_addr      = "{{ GetPrivateIP }}"
advertise_addr = "{{ GetPrivateIP }}"

# 指向 Consul Server（由環境變數 CONSUL_SERVER_IP 提供，compose 預設 10.0.2.11）
retry_join = ["{{ env \"CONSUL_SERVER_IP\" }}"]
