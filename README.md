# borsh-zig

A [Zig](https://ziglang.org) implementation of the [Borsh](https://borsh.io/) binary format specification.

## Setup

In build.zig:

```zig
const std = @import("std");

const borsh_pkg: std.build.Pkg = .{
    .name = "borsh",
    .path = .{ .path = "borsh-zig/borsh.zig" },
};

// Assume 'step' is a *std.build.LibExeObjStep.
step.addPackage(borsh_pkg);
```

## Specification

Refer to the official [specification](https://borsh.io/).