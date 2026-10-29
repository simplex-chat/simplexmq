# CI on GitHub's runners

## Builds

`build.yml` runs one of two builds:

| Trigger | Build | Jobs |
|---|---|---|
| a push to a draft pull request<br>a manual run (workflow_dispatch)<br>a push to master or stable in a fork | reduced | build-reduced: ubuntu-24.04 x86-64, GHC 9.6.3, at -O0 (-O2 on pushes), without the standard build |
| a pull request marked ready for review, and later pushes to it<br>a push to master or stable in simplex-chat/simplexmq<br>a push of a v* tag | full | build: 5 entries (GHC 8.10.7 and 9.6.3, x86-64 and aarch64), at -O0 on pull requests and -O2 on pushes |

Both builds also run maybe-release and resolver (python). Tests run on the x86-64 entries. The reduced build restores the -O0 build caches saved by master pushes; the Docker image cache is tagged by ISO week, so the first run of a week rebuilds the image.

## Test selection

- Draft pull request: a fenced block with the info string `ci-tests` in the description, one hspec match pattern per line. The block is read at each push; an edit applies from the next push.
- Manual run: input `tests`, one pattern per line.
- `/` runs all tests. With no pattern, a reduced build runs no tests. A full build runs all tests and ignores the selection.
- Each pattern is passed as `-m <pattern>`. With at least one pattern, `--fail-on=empty` is added, so a pattern that matches nothing fails the run.
- A pattern matches the item path `/group/subgroup/item/` as a substring. Group names are the `describe` names in tests/Test.hs.

Example block:

````
```ci-tests
/Core tests/Encoding tests/
SMP proxy
```
````

## Manual run

```sh
curl -fsS -X POST \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/<owner>/simplexmq/actions/workflows/build.yml/dispatches \
  -d '{"ref": "<branch>", "inputs": {"tests": "/Core tests/Encoding tests/\nSMP proxy"}}'
```

A manual run starts on a branch; a release is retried by re-running the jobs of its tag push.

## Local run

scripts/ci/run-tests.sh runs the selection as in CI: it appends the patterns of `TESTS` to the test command.

```sh
cabal build --enable-tests --ghc-options=-O0 simplexmq-test
TESTS='/Core tests/Encoding tests/' scripts/ci/run-tests.sh "$(cabal list-bin simplexmq-test --ghc-options=-O0)"
```
