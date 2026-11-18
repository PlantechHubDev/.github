Deploy orchestration-service @S7@ to prod: the image the merge queue built and simulated (not rebuilt). `:master` was not moved, because a prod unit pins `:master` or could not be read (plantechhub/us-east-1/prod/orchestration-service/terragrunt.hcl plantechhub/us-west-2/prod/orchestration-service/terragrunt.hcl), so this PR pins the image by digest.

- Image: `registry.example.test/orchestration-service@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
- Commit: https://github.com/PlantechHubDev/orchestration-service/commit/@MERGE@
- Simulation: https://github.com/PlantechHubDev/orchestration-service/actions/runs/42

Rollback digest: sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

## Service PRs (@DEPLOYED7@..@S7@)

- PlantechHubDev/orchestration-service#11
- PlantechHubDev/orchestration-service#12
