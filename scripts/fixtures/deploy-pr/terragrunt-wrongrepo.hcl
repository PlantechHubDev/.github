# Prod unit for example-service (fixture for scripts/test-open-deploy-pr.sh).
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://example.test/modules.git//service?ref=v1.2.3"
}

inputs = {
  service_name   = "example-service"
  # image = "registry.example.test/example-service:old"
    image          = "registry.example.test/other-service:master"   # pinned by the release workflow
  sidecar_image  = "registry.example.test/log-router:stable"
  container_port = 8080
}
