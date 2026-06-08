# macOS OpenGL/Metal interop POC

This tool validates the dangerous part of the Metal present bridge outside the
game process: binding an `IOSurface` to OpenGL with `CGLTexImageIOSurface2D`,
attaching it to an FBO, and importing the same surface as a Metal texture.

Build:

```sh
tools/macos-gl-metal-interop-poc/build.sh
```

Run:

```sh
tools/macos-gl-metal-interop-poc/build/gl_metal_interop_poc --width 1496 --height 935
```

Expected output contains one `GL_METAL_INTEROP_ATTEMPT` result per tested
format/target pair and a final `GL_METAL_INTEROP_SUMMARY ok=0|1`.

Keep this validation out of ITGmania boot until this POC finds a stable
combination on the target machines.
