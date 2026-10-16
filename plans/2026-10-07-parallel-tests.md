# Parallel test execution

Every test gets its own ports, directory and Postgres schemas, so hspec runs
the tree concurrently in one process with `parallel` and `--jobs`.

## Decisions

- `Util` defines the test environment:

  ```haskell
  data TestEnv = TestEnv
    { testNo :: Int,
      portBase :: Int
    }

  type HasTestEnv = (?testEnv :: TestEnv)
  ```

- `Util.it`, `fit` and `xit` take `HasTestEnv => a`. The test wrapper
  creates the environment for each attempt, so a CI retry gets fresh ports,
  directory and schemas.
- Environment creation:
  - `testNo` from a counter, never reused in a run.
  - `portBase` from a pool `[10000, 10010 .. 19990]`, returned after the test.
  - directory `tests/tmp/<testNo>` with `xftp-sender-files` and
    `xftp-recipient-files`, removed after the test.
- Fixture constants become `HasTestEnv =>` values:
  - ports: offsets from `portBase`

    | offset | fixture         |
    |--------|-----------------|
    | 1      | `testPort`      |
    | 2      | `testPort2`     |
    | 3      | `ntfTestPort`   |
    | 4      | `ntfTestPort2`  |
    | 5      | `apnsTestPort`  |
    | 6      | `xftpTestPort`  |
    | 7      | `xftpTestPort2` |

  - server addresses: built from the ports.
  - files: in the test directory.
  - Postgres schemas: `test<testNo>_<name>`.
- Functions that use fixtures gain `HasTestEnv` in their signatures.
- `withXFTPServerCfg` creates the server files directory.
- Removed hooks:
  - `tests/tmp` creation and removal per test.
  - per-test database recreation and schema drops.
  - XFTP `testBracket` and server files directory hooks.
  - `around (withMsgStore cfg)`: each test opens its store.
- `tests/tmp` is cleared before the run and removed after it.
- Postgres databases are created before the run and dropped after it.
- Schema dumps and the Ntf CLI test keep the production schema names and
  recreate the database per test.
- Sequential, after all parallel tests:
  - SMP proxy tests that change the number of capabilities.
  - XFTP CLI tests: `withArgs` and stdout capture are process-wide.
  - server CLI tests: the same, and fixed ports.
  - tests with wall-clock assertions:
    - retry intervals
    - AUTH error timing
    - agent user network info
    - agent SMP queue info
    - agent client notices
  - schema dumps.
- The SQLite agent schema dump resets `tests/tmp` after each item.
- `createRandomFile_` in the XFTP agent tests writes random bytes directly.
- Test suite `-with-rtsopts=-N1` becomes `-with-rtsopts=-N`.
- `it "..." . f $ x` becomes `it "..." $ f $ x` where `f` or `x` uses the
  environment.

## Mechanics

- `tests/Util.hs`: environment, wrapper, `it`, `fit`, `xit`,
  `eventuallyRemove`, sender and recipient directories.
- `tests/Test.hs`: `parallel` tree, sequential tail, `tests/tmp` and database
  brackets around `hspec`.
- `tests/SMPClient.hs`, `tests/SMPAgentClient.hs`, `tests/NtfClient.hs`,
  `tests/XFTPClient.hs`, `tests/Fixtures.hs`: fixtures from the environment.
- Test modules: signatures, literal paths and ports, removed hooks.
- `simplexmq.cabal`: `-N`.
