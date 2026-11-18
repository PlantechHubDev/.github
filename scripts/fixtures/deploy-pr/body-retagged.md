Deploy orchestration-service @S7@ to prod: the image the merge queue built and simulated, retagged as `:master` without rebuilding.

- Image: `registry.example.test/orchestration-service@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
- Commit: https://github.com/PlantechHubDev/orchestration-service/commit/@MERGE@
- Simulation: https://github.com/PlantechHubDev/orchestration-service/actions/runs/42

Rollback digest: sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

## Service PRs (@DEPLOYED7@..@S7@)

- PlantechHubDev/orchestration-service#11
- PlantechHubDev/orchestration-service#12
