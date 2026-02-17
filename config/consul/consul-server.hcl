datacenter = "dc1"
data_dir   = "/consul/data"
log_level  = "INFO"

server = true
bootstrap_expect = 1

ui_config { enabled = true }

# ✅ 綁定 ens5
bind_addr      = "{{ GetInterfaceIP \"ens5\" }}"
advertise_addr = "{{ GetInterfaceIP \"ens5\" }}"

ports {
  dns = 8600
}
