# x

```yaml
# ci.yml
name: ci
on:
  pull_request:
  merge_group:
jobs:
  gate:
    name: ci-ok
    runs-on: ubuntu-latest
    steps:
      - run: true
```
