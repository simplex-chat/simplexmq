# Contributing to SimpleX repositories

## Focus on user problems

We do not make code changes to improve code - any change must address a specific user problem or request.

## Discuss the plans as early as possible

Please discuss the problem you want to solve and your detailed implementation plan with the project team prior to contributing, to avoid wasted time and additional changes. Acceptance of your contribution depends on your willingness and ability to iterate the proposed contribution to achieve the required quality level, coding style, test coverage, and alignment with user requirements as they are understood by the project team.

## Follow project structure, coding style and approaches

./PROJECT.md has information about the structure of this `simplexmq` repository.

./CODE.md has details about general requirements common for `simplexmq` and `simplex-chat` repositories.

CLAUDE.md in the repository root imports these files, this guide and ../scripts/ci/README.md for Claude Code.

## Pull requests and CI

1. Open a pull request to `master` as a draft. On a draft, CI runs the reduced build: one Linux job ([CI guide](../scripts/ci/README.md)).
2. Select the tests in a `ci-tests` block in the description, one hspec match pattern per line. `/` runs all tests; without a block, the reduced build runs no tests.
3. Push the changes for review comments to the same branch; each push runs the reduced build.
4. Reviewers approve the draft. A draft cannot be merged.
5. After the approval, mark the pull request ready for review. CI then runs the full matrix, and the pull request is merged by squash once it passes.
