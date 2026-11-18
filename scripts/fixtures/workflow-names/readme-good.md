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
      - run: true
```
