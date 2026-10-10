---
name: build
description: Build, ad-hoc sign, package, and verify a shareable Pixeltje Mac release ZIP. Use when the user invokes build or asks for a distributable release archive.
---

# Build Release ZIP

From the repository root, run:

```sh
.agents/skills/build/scripts/build-release.sh
```

The helper uses the repository's release app packager with the Xcode beta
toolchain, verifies the resulting app signature, creates a new ZIP in
`~/Desktop/pixeltje-macosx-builds`, tests the ZIP, and prints its path, size,
architecture, minimum macOS version, and SHA-256 digest. If the normal filename
already exists, it adds a timestamp rather than overwriting it.

Writing to the Desktop or allowing Swift to use its compiler caches may require
running the helper with approval outside the sandbox. Request that approval
immediately before execution. Do not choose a different destination unless the
user asks for one, and never report success if signature or archive validation
fails.

The output is ad-hoc signed, not Developer ID signed or notarized. State that
when handing the archive back to the user.
