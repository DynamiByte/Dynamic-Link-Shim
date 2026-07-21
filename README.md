# Dynamic Link Shim

Dynamic Link Shim is a small Zig tool for building DLL proxies.

DLS takes an existing Windows DLL, generates a replacement DLL with the same exports, forwards those exports to the original DLL, and loads the DLLs you configure when the host process starts.

In plain terms: pick a DLL that something already loads, tell DLS what companion DLLs to load, and DLS builds a drop-in proxy for that DLL.

![Version](https://img.shields.io/badge/version-0.5.0-blue)
![License](https://img.shields.io/badge/license-AGPL--3.0-green)

---

## Disclaimer

Using with with some software may violate their ToS. Use it at your own risk.

---

## Quick Start

1. Pick the DLL you want to proxy
2. Configure the DLLs you want loaded
3. Run `zig build`
4. Use the generated proxy DLL from `zig-out/bin`

Example:

```bash
zig build -- --input "Library.dll" --load "Patch.dll"
```

DLS reads exports from `Library.dll`, generates a proxy named `Library.dll`, forwards the original exports to the backing DLL, and loads `Patch.dll` when the proxy starts.

To keep the reusable export surface without storing the source DLL, compile it once:

```bash
zig build surface -- --input "Library.dll"
```

This writes `zig-out/bin/Library.dls`. A `.dls` file is a compact binary description of the target DLL, architecture, ordinal range, and exports. It contains no source DLL bytes or source hash.

Use it anywhere the source DLL would otherwise be needed for proxy generation:

```bash
zig build -- --input "Library.dls" --load "Patch.dll"
```

The stored target name supplies the default `Library.dll` output and `Library.og.dll` forward target. Renaming the `.dls` file does not change that identity. `output_pair` and `embed_dlls` still need the original bytes; provide them with `backing` or `--backing`.

To load every `*.dls.dll` file beside the proxy, enable DLS autoloading:

```bash
zig build -- --autoload
```

Autoloaded companions use `.dls.dll` as their identifying suffix, for example `Patch.dls.dll`. DLS loads them in case-insensitive filename order.

If the patch must be injected at process startup, before the game's main thread begins running, use bootstrap mode:

```bash
zig build -- --input "Library.dll" --load "Patch.dll" --bootstrap
```

In bootstrap mode, the proxy checks whether the configured load DLLs are already present. If they are missing, it starts a fresh suspended copy of the same process, injects the load DLLs with remote `LoadLibraryW`, resumes the new process, and exits the original process. Runtime DLL paths are resolved beside the proxy DLL.

For an install-style folder, DLS can rename the original DLL to the resolved `forward` path and copy the proxy beside it:

```bash
zig build -- --input "/Game/Library.dll" --load "Patch.dll" --copy-to-input-dir
```

Example layout after install:

```text
Library.dll        <- generated proxy
Library.og.dll     <- original backing DLL
Patch.dll          <- DLL loaded by the proxy
```

To output a pair without changing the input folder:

```bash
zig build -- --input "/Game/Library.dll" --load "Patch.dll" --output-pair
```

This writes the proxy as `Library.dll` and the backing DLL as `Library.og.dll` in the build output. Add `--copy-to DIR` to put the pair somewhere else.

To fold the backing DLL and loaded DLLs into the generated proxy:

```bash
zig build -- --input "/Game/Library.dll" --load "Patch.dll" --embed-dlls
```

This embeds `Library.og.dll` and each configured `--load` DLL as raw bytes inside `Library.dll`. At runtime, the proxy extracts them into the current folder when they are missing or their SHA-256 hashes differ, then loads them normally. Pass `--load` more than once to embed multiple patch DLLs.

---

## Configuration

DLS reads `config.zon` beside `build.zig` by default. The file in this repo is the editable example and documents each option inline.

Main fields:

- `input`: DLL or compiled `.dls` export surface
- `backing`: optional original DLL bytes used by `output_pair` and `embed_dlls`
- `forward`: original DLL the proxy forwards to
- `output`: generated proxy DLL name
- `method`: `runtime_stub` by default, or `pe_forwarder`
- `load`: DLLs loaded by the proxy
- `autoload`: load every `*.dls.dll` file beside the proxy
- `load_import`: import used by `pe_forwarder` to load DLLs
- `copy_to`: optional output copy directory
- `output_pair`: also output/copy the backing DLL beside the proxy
- `embed_dlls`: embed the backing DLL and loaded DLLs into the runtime stub
- `bootstrap`: restart through suspended-process injection when loaded DLLs are missing
- `forwarding`: export handling options

Use another config file:

```bash
zig build -- --config "some-file.zon"
```

Override the method:

```bash
zig build -Dmethod=runtime_stub
zig build -Dmethod=pe_forwarder
```

Enable pair output, embedded output, startup bootstrap, or input-folder copying with command arguments:

```bash
zig build -- --output-pair
zig build -- --embed-dlls
zig build -- --bootstrap
zig build -- --copy-to-input-dir
```

Command arguments go after `--` and override config values:

```bash
zig build -- --input "Library.dll" --forward "Library.og.dll" --load "PatchA.dll" --load "PatchB.dll"
```

Useful command arguments:

- `--input [PATH]`
- `--backing [PATH]`
- `--forward [PATH]`
- `--output [NAME]`
- `--load [PATH]`; can be repeated
- `--autoload`
- `--import [NAME_OR_ORDINAL]`
- `--copy-to [DIR]`
- `--copy-to-input-dir`
- `--output-pair`
- `--embed-dlls`
- `--bootstrap`

---

## Methods

### `runtime_stub`

`runtime_stub` is the default method.

It builds a normal DLL with real exported stubs. At runtime, the proxy loads configured DLLs with `LoadLibraryW`, loads the backing DLL with `LoadLibraryW`, resolves exports with `GetProcAddress`, then jumps to the resolved export.

When `embed_dlls` is enabled, this method also embeds the backing DLL and configured loaded DLLs as raw bytes, extracts them into the current folder if they are missing or their SHA-256 hashes differ, then continues through the same loading path.

When `bootstrap` is enabled, this method restarts the current executable suspended and injects the configured load DLLs if they are not already loaded. This is useful when the loaded DLL needs the same startup shape as a launcher/injector.

This is the safer default when the host expects real exported functions from the proxy DLL.

### `pe_forwarder`

`pe_forwarder` emits a tiny PE forwarder DLL directly.

This mirrors the reference forwarder style: companion DLLs are loaded through the PE import table, while exports are represented as PE export forwarders to `forward`.

For `pe_forwarder`, each loaded DLL must export the configured `load_import` name or ordinal. `#1` is the default. Embedded DLL extraction is only supported by `runtime_stub`.

---

## Building

To build from source, use Zig 0.16.0:

- [Windows x86_64](https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip)
- [Linux x86_64](https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz)

<details>
<summary>Other Zig 0.16.0 downloads</summary>

Files are signed with [minisign](https://jedisct1.github.io/minisign/) using this public key:

```text
RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
```

- 2026-04-13
- [Release Notes](https://ziglang.org/download/0.16.0/release-notes.html)
- [Language Reference](https://ziglang.org/documentation/0.16.0/)
- [Standard Library Documentation](https://ziglang.org/documentation/0.16.0/std/)

<table>
<thead>
<tr><th>OS</th><th>Arch</th><th>Filename</th><th>Signature</th><th>Size</th></tr>
</thead>
<tbody>
<tr><td colspan="2" rowspan="2" align="center">Source</td><td><a href="https://ziglang.org/download/0.16.0/zig-0.16.0.tar.xz">zig-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-0.16.0.tar.xz.minisig">minisig</a></td><td>21MiB</td></tr>
<tr><td><a href="https://ziglang.org/download/0.16.0/zig-bootstrap-0.16.0.tar.xz">zig-bootstrap-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-bootstrap-0.16.0.tar.xz.minisig">minisig</a></td><td>53MiB</td></tr>
</tbody>
<tbody>
<tr><td rowspan="3" align="center">Windows</td><td>x86_64</td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip">zig-x86_64-windows-0.16.0.zip</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip.minisig">minisig</a></td><td>93MiB</td></tr>
<tr><td>aarch64</td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-windows-0.16.0.zip">zig-aarch64-windows-0.16.0.zip</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-windows-0.16.0.zip.minisig">minisig</a></td><td>89MiB</td></tr>
<tr><td>x86</td><td><a href="https://ziglang.org/download/0.16.0/zig-x86-windows-0.16.0.zip">zig-x86-windows-0.16.0.zip</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-x86-windows-0.16.0.zip.minisig">minisig</a></td><td>94MiB</td></tr>
</tbody>
<tbody>
<tr><td rowspan="2" align="center">macOS</td><td>x86_64</td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-macos-0.16.0.tar.xz">zig-x86_64-macos-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-macos-0.16.0.tar.xz.minisig">minisig</a></td><td>55MiB</td></tr>
<tr><td>aarch64</td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz">zig-aarch64-macos-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz.minisig">minisig</a></td><td>50MiB</td></tr>
</tbody>
<tbody>
<tr><td rowspan="8" align="center">Linux</td><td>x86_64</td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz">zig-x86_64-linux-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz.minisig">minisig</a></td><td>53MiB</td></tr>
<tr><td>aarch64</td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz">zig-aarch64-linux-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz.minisig">minisig</a></td><td>49MiB</td></tr>
<tr><td>arm</td><td><a href="https://ziglang.org/download/0.16.0/zig-arm-linux-0.16.0.tar.xz">zig-arm-linux-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-arm-linux-0.16.0.tar.xz.minisig">minisig</a></td><td>50MiB</td></tr>
<tr><td>riscv64</td><td><a href="https://ziglang.org/download/0.16.0/zig-riscv64-linux-0.16.0.tar.xz">zig-riscv64-linux-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-riscv64-linux-0.16.0.tar.xz.minisig">minisig</a></td><td>53MiB</td></tr>
<tr><td>powerpc64le</td><td><a href="https://ziglang.org/download/0.16.0/zig-powerpc64le-linux-0.16.0.tar.xz">zig-powerpc64le-linux-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-powerpc64le-linux-0.16.0.tar.xz.minisig">minisig</a></td><td>53MiB</td></tr>
<tr><td>x86</td><td><a href="https://ziglang.org/download/0.16.0/zig-x86-linux-0.16.0.tar.xz">zig-x86-linux-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-x86-linux-0.16.0.tar.xz.minisig">minisig</a></td><td>56MiB</td></tr>
<tr><td>loongarch64</td><td><a href="https://ziglang.org/download/0.16.0/zig-loongarch64-linux-0.16.0.tar.xz">zig-loongarch64-linux-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-loongarch64-linux-0.16.0.tar.xz.minisig">minisig</a></td><td>50MiB</td></tr>
<tr><td>s390x</td><td><a href="https://ziglang.org/download/0.16.0/zig-s390x-linux-0.16.0.tar.xz">zig-s390x-linux-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-s390x-linux-0.16.0.tar.xz.minisig">minisig</a></td><td>52MiB</td></tr>
</tbody>
<tbody>
<tr><td rowspan="5" align="center">FreeBSD</td><td>aarch64</td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-freebsd-0.16.0.tar.xz">zig-aarch64-freebsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-freebsd-0.16.0.tar.xz.minisig">minisig</a></td><td>49MiB</td></tr>
<tr><td>arm</td><td><a href="https://ziglang.org/download/0.16.0/zig-arm-freebsd-0.16.0.tar.xz">zig-arm-freebsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-arm-freebsd-0.16.0.tar.xz.minisig">minisig</a></td><td>50MiB</td></tr>
<tr><td>powerpc64le</td><td><a href="https://ziglang.org/download/0.16.0/zig-powerpc64le-freebsd-0.16.0.tar.xz">zig-powerpc64le-freebsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-powerpc64le-freebsd-0.16.0.tar.xz.minisig">minisig</a></td><td>53MiB</td></tr>
<tr><td>riscv64</td><td><a href="https://ziglang.org/download/0.16.0/zig-riscv64-freebsd-0.16.0.tar.xz">zig-riscv64-freebsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-riscv64-freebsd-0.16.0.tar.xz.minisig">minisig</a></td><td>53MiB</td></tr>
<tr><td>x86_64</td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-freebsd-0.16.0.tar.xz">zig-x86_64-freebsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-freebsd-0.16.0.tar.xz.minisig">minisig</a></td><td>53MiB</td></tr>
</tbody>
<tbody>
<tr><td rowspan="4" align="center">NetBSD</td><td>aarch64</td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-netbsd-0.16.0.tar.xz">zig-aarch64-netbsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-netbsd-0.16.0.tar.xz.minisig">minisig</a></td><td>49MiB</td></tr>
<tr><td>arm</td><td><a href="https://ziglang.org/download/0.16.0/zig-arm-netbsd-0.16.0.tar.xz">zig-arm-netbsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-arm-netbsd-0.16.0.tar.xz.minisig">minisig</a></td><td>51MiB</td></tr>
<tr><td>x86</td><td><a href="https://ziglang.org/download/0.16.0/zig-x86-netbsd-0.16.0.tar.xz">zig-x86-netbsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-x86-netbsd-0.16.0.tar.xz.minisig">minisig</a></td><td>56MiB</td></tr>
<tr><td>x86_64</td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-netbsd-0.16.0.tar.xz">zig-x86_64-netbsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-netbsd-0.16.0.tar.xz.minisig">minisig</a></td><td>53MiB</td></tr>
</tbody>
<tbody>
<tr><td rowspan="4" align="center">OpenBSD</td><td>aarch64</td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-openbsd-0.16.0.tar.xz">zig-aarch64-openbsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-aarch64-openbsd-0.16.0.tar.xz.minisig">minisig</a></td><td>49MiB</td></tr>
<tr><td>arm</td><td><a href="https://ziglang.org/download/0.16.0/zig-arm-openbsd-0.16.0.tar.xz">zig-arm-openbsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-arm-openbsd-0.16.0.tar.xz.minisig">minisig</a></td><td>50MiB</td></tr>
<tr><td>riscv64</td><td><a href="https://ziglang.org/download/0.16.0/zig-riscv64-openbsd-0.16.0.tar.xz">zig-riscv64-openbsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-riscv64-openbsd-0.16.0.tar.xz.minisig">minisig</a></td><td>53MiB</td></tr>
<tr><td>x86_64</td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-openbsd-0.16.0.tar.xz">zig-x86_64-openbsd-0.16.0.tar.xz</a></td><td><a href="https://ziglang.org/download/0.16.0/zig-x86_64-openbsd-0.16.0.tar.xz.minisig">minisig</a></td><td>54MiB</td></tr>
</tbody>
</table>

</details>

Build the configured proxy with:

```bash
zig build
```

The default build uses `ReleaseSmall` and writes:

```bash
./zig-out/bin/Library.dll
```

Inspect the configured export map without building the proxy:

```bash
zig build inspect
```

Compile the configured DLL into a reusable binary export surface:

```bash
zig build surface
```

## Build API

Projects using DLS as a Zig dependency can add a proxy directly to their build graph:

```zig
const dls = @import("dynamic_link_shim");

const dependency = b.dependency("dynamic_link_shim", .{});
const proxy = dls.addProxy(b, dependency, .{
    .target = target,
    .input = "UnityPlayer.dll",
    .export_source = b.path("assets/UnityPlayer.dll"),
    .forward = "UnityPlayer.og.dll",
    .load = &.{.{ .name = "Patch.dll", .source = patch.getEmittedBin() }},
    .bootstrap = true,
});

const install = b.addInstallFileWithDir(proxy.dll, .bin, proxy.output_name);
b.getInstallStep().dependOn(&install.step);
```

The returned proxy includes its generated DLL path, output names, optional backing DLL, and the runtime-stub compile step when one exists. Consumers can attach resources to `proxy.compile` without reproducing DLS's generator and linker setup.

`export_source` may point to either the original DLL or a compiled `.dls` file. When using `.dls` with `output_pair` or `embed_dlls`, set `backing_source` to the original DLL explicitly.
