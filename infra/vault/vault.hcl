storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:18200"
  tls_disable = 1
}

api_addr = "http://127.0.0.1:18200"
ui = true

disable_mlock = true