datacenter = "dc1"
data_dir   = "/consul/data"
log_level  = "INFO"

server = false

# ✅ 綁定 ens5
bind_addr      = "{{ GetInterfaceIP \"ens5\" }}"
advertise_addr = "{{ GetInterfaceIP \"ens5\" }}"

# 指向 Consul Server（由環境變數 CONSUL_SERVER_IP 提供，compose 預設 10.0.2.11）
retry_join = ["{{ env \"CONSUL_SERVER_IP\" }}"]
