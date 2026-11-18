# Prod unit for orchestration-service (fixture for scripts/test-open-deploy-pr.sh).
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/PlantechHubDev/infrastructure-modules.git//ecs-service?ref=v1.2.3"
}

inputs = {
  service_name   = "orchestration-service"
  # image = "registry.example.test/orchestration-service:old"
    image          = "registry.example.test/orchestration-service@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"   # pinned by the release workflow
  sidecar_image  = "registry.example.test/log-router:stable"
  container_port = 8080
}
