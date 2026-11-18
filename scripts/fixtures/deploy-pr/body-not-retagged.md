Deploy example-service @S7@ to prod: the image the merge queue built and simulated (not rebuilt). `:master` was not moved, because a prod unit pins `:master` or could not be read (live/region-a/prod/example-service/terragrunt.hcl live/region-b/prod/example-service/terragrunt.hcl), so this PR pins the image by digest.

- Image: `registry.example.test/example-service@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
- Commit: https://github.com/PlantechHubDev/example-service/commit/@MERGE@
- Simulation: https://github.com/PlantechHubDev/example-service/actions/runs/42

Rollback digest: sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

## Service PRs (@DEPLOYED7@..@S7@)

- PlantechHubDev/example-service#11
- PlantechHubDev/example-service#12
