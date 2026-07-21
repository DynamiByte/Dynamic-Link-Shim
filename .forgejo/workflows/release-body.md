# Dynamic Link Shim

Dynamic Link Shim is a small Zig tool for building DLL proxies.

DLS takes an existing Windows DLL, generates a replacement DLL with the same exports, forwards those exports to the original DLL, and loads the DLLs you configure when the host process starts.

![Version](https://img.shields.io/badge/version-{{VERSION}}-blue)
![License](https://img.shields.io/badge/license-AGPL--3.0-green)

## Quick Start

Pick a DLL that something already loads, then tell DLS what companion DLLs to load:

```bash
zig build -- --input "Library.dll" --load "Patch.dll"
```

DLS reads exports from `Library.dll`, generates a proxy named `Library.dll`, forwards the original exports to the backing DLL, and loads `Patch.dll` when the host process starts.

For more usage information, see [the README]({{README_URL}}).

## Disclaimer

Some software may treat DLL replacement or wrapper DLLs as unsupported or against their terms of service. Use DLS at your own risk.

## Changelog

