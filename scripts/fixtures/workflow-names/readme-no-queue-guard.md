# x

```yaml
# ci.yml
name: ci
on:
  pull_request:
    branches: [master]
  merge_group:
jobs:
  ci-ok:
    runs-on: ubuntu-latest
    steps:
      - uses: re-actors/alls-green@b5b5b37504aa4183270bd3d855c52a67f212be35 # v1.3.0
        with:
          allowed-skips: test, image, pth-sim
```
