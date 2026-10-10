---
name: version
description: Set the Pixeltje Mac release version consistently across bundle metadata and product-facing version responses. Use when the user invokes version or asks to change, bump, or prepare the app version.
---

# Set Release Version

Require one version argument containing two or three dot-separated non-negative
integers, such as `0.2` or `1.4.3`.

From the repository root, run:

```sh
.agents/skills/version/scripts/set-version.sh VERSION
```

The helper updates and verifies all product-facing version locations:

- `Resources/Info.plist` (`CFBundleShortVersionString`)
- the MCP server's `serverInfo.version`
- the standard About panel's application version

Do not change `CFBundleVersion`; it is the independent build number. Report the
old and new release versions and the changed files. Never report success if the
helper detects inconsistent existing versions or fails verification.
