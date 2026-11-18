# Prod unit for orchestration-service (fixture for scripts/test-open-deploy-pr.sh).
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/PlantechHubDev/infrastructure-modules.git//ecs-service?ref=v1.2.3"
}

inputs = {
  service_name   = "orchestration-service"
  # image = "000000000000.dkr.ecr.us-east-1.amazonaws.com/orchestration-service:old"
    image          = "000000000000.dkr.ecr.us-east-1.amazonaws.com/orchestration-service:master"   # pinned by the release workflow
  sidecar_image  = "000000000000.dkr.ecr.us-east-1.amazonaws.com/log-router:stable"
  container_port = 8080
}
image = "again"
