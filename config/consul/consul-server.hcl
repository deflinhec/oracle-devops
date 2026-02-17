datacenter = "dc1"
data_dir   = "/consul/data"
log_level  = "INFO"

server = true
bootstrap_expect = 1

ui_config { enabled = true }

# 綁定本機私網 IP（不依賴介面名稱，適用各節點）
bind_addr      = "{{ GetPrivateIP }}"
advertise_addr = "{{ GetPrivateIP }}"

ports {
  dns = 8600
}
