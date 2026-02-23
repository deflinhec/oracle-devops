datacenter = "dc1"
data_dir   = "/consul/data"
log_level  = "INFO"

server = false

# 綁定本機私網 IP（不依賴介面名稱，適用各節點）
bind_addr      = "{{ GetPrivateIP }}"
advertise_addr = "{{ GetPrivateIP }}"

# retry_join 改由 compose command 傳入 -retry-join=${CONSUL_SERVER_IP}
