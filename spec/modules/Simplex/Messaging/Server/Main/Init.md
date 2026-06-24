# Simplex.Messaging.Server.Main.Init

> Router initialization: INI file content generation, default settings, and CLI option structures.

**Source**: [`Main/Init.hs`](../../../../../../src/Simplex/Messaging/Server/Main/Init.hs)

## iniFileContent — selective commenting

`iniFileContent` uses `optDisabled`/`optDisabled'` to conditionally comment out INI settings. A setting appears commented when it was not explicitly provided or matches the default value. Consequence: regenerating the INI file after user changes will re-comment modified-to-default values, making it appear the user's change was reverted.

## iniDbOpts — default fallback

Database connection settings are uncommented only if they differ from `defaultDBOpts`. A custom connection string that matches the default will appear commented.

## Control port passwords — independent generation

Admin and user control port passwords are generated as two independent `randomBase64 18` calls during initialization. Despite `let pwd = ... in (,) <$> pwd <*> pwd` appearing to share a value, `pwd` is an IO action — applicative `<*>` executes it twice, producing two different random passwords. The INI template thus has distinct admin and user passwords.
