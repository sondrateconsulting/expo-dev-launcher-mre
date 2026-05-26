# expo-dev-launcher-mre

Minimal reproduction for an Xcode 26 build cycle caused by `expo-dev-launcher@56.0.15`.

## Summary

`expo-dev-launcher`'s config plugin adds a `PBXShellScriptBuildPhase` named **"Strip Local Network Keys for Release"** that declares `Info.plist` as an `inputPaths` entry and mutates that same file in place via `PlistBuddy` — but never declares any `outputPaths`. Under Xcode 26's tightened dependency analyzer, the missing output edge is fatal: every archive build aborts with `error: Cycle inside <target>`.

## Affected versions

Observed against:

| Package              | Version |
| -------------------- | ------- |
| `expo`               | 56.0.4  |
| `expo-dev-client`    | 56.0.15 |
| `expo-dev-launcher`  | 56.0.15 |
| `react-native`       | 0.85.3  |
| Xcode                | 26.x    |
| iOS SDK              | 26.x    |

Older Xcode releases (15.x) tolerate the missing output declaration and the bug is latent.

## Reproduction

```bash
npm install
npx expo prebuild --clean --platform ios --no-install
bash scripts/verify-bug.sh
```

Expected output:

```text
=== Build phase as emitted by expo-dev-launcher ===

  isa = PBXShellScriptBuildPhase;
  ...
  name = "[Expo Dev Launcher] Strip Local Network Keys for Release";
  inputPaths = (
    "$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)",
  );
  outputPaths = (
  );
  shellPath = /bin/sh;

=== Outputs check ===
BUG CONFIRMED: outputPaths is empty.
```

The script exits non-zero when the bug is present so it works as a regression gate.

To observe the full failure end-to-end, continue with:

```bash
cd ios
bundle install            # uses Ruby 3.2 (see .ruby-version)
bundle exec pod install
xcodebuild \
  -workspace expodevlaunchermre.xcworkspace \
  -scheme expodevlaunchermre \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  archive
```

On Xcode 26, the archive aborts with:

```text
error: Cycle inside expodevlaunchermre; building could produce unreliable results.
This usually can be resolved by moving the shell script phase
'[Expo Dev Launcher] Strip Local Network Keys for Release'
so that it runs before the build phase that depends on its outputs.
```

## Root cause

The phase is injected here in [`expo-dev-launcher/plugin/src/withDevLauncher.ts#L47-L85`](https://github.com/expo/expo/blob/6dfb0e4c958a1ea1d66d3f7952494ac58430ad45/packages/expo-dev-launcher/plugin/src/withDevLauncher.ts#L47-L85) (pinned to the `expo-dev-launcher@56.0.15` publish commit):

```ts
project.addBuildPhase([], 'PBXShellScriptBuildPhase', buildPhaseName, nativeTargetId, {
  shellPath: '/bin/sh',
  inputPaths: ['"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"'],
  shellScript: `
    if [ "$CONFIGURATION" != "Debug" ]; then
      PLIST_PATH="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
      # ...PlistBuddy -c "Delete :NSBonjourServices:$i" "$PLIST_PATH"...
    fi
  `,
});
```

The script reads `Info.plist` and writes back to the same path. Without a matching `outputPaths` declaration, Xcode 26 cannot prove the script's effect is acyclic and reports a cycle.

## Suggested upstream fix

Add the missing output declaration:

```ts
project.addBuildPhase([], 'PBXShellScriptBuildPhase', buildPhaseName, nativeTargetId, {
  shellPath: '/bin/sh',
  inputPaths: ['"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"'],
  outputPaths: ['"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"'],
  shellScript: `...`,
});
```

Equivalent: mark the phase `alwaysOutOfDate: 1` to opt out of dependency analysis entirely. The `outputPaths` declaration is preferred — it preserves incremental-build correctness.

## Downstream workaround

Until the upstream fix ships, a config plugin that runs after `expo-dev-launcher` and back-fills the `outputPaths` on the existing build phase unblocks affected apps:

```ts
import { withXcodeProject, type ConfigPlugin } from "@expo/config-plugins";

const PHASE_NAME = "[Expo Dev Launcher] Strip Local Network Keys for Release";
const INFOPLIST = '"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"';
const COMMENT_KEY = /_comment$/;

const withDevLauncherCycleFix: ConfigPlugin = (config) =>
  withXcodeProject(config, (config) => {
    const section =
      config.modResults.hash.project.objects.PBXShellScriptBuildPhase;
    if (!section) return config;
    for (const key of Object.keys(section)) {
      if (!COMMENT_KEY.test(key)) continue;
      if (section[key] !== PHASE_NAME) continue;
      const phase = section[key.replace(COMMENT_KEY, "")];
      if (phase && typeof phase === "object") {
        phase.outputPaths = [INFOPLIST];
      }
    }
    return config;
  });

export default withDevLauncherCycleFix;
```

Iterate every matching phase, not just the first, in case a future version of `expo-dev-launcher` attaches the phase to multiple targets.

## License

MIT
