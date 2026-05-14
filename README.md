# Dynamic Link Shim

Dynamic Link Shim is a small Zig tool for building DLL proxies.

DLS takes an existing Windows DLL, generates a replacement DLL with the same exports, forwards those exports to the original DLL, and loads the DLLs you configure when the host process starts.

In plain terms: pick a DLL that something already loads, tell DLS what companion DLLs to load, and DLS builds a drop-in proxy for that DLL.

![Version](https://img.shields.io/badge/version-0.4.0-blue)
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
zig build -Dinput=Library.dll -Dload=Patch.dll
```

DLS reads exports from `Library.dll`, generates a proxy named `Library.dll`, forwards the original exports to the backing DLL, and loads `Patch.dll` when the proxy starts.

If the patch must be injected at process startup, before the game's main thread begins running, use bootstrap mode:

```bash
zig build -Dinput=Library.dll -Dload=Patch.dll -Dbootstrap=true
```

In bootstrap mode, the proxy checks whether the configured load DLLs are already present. If they are missing, it starts a fresh suspended copy of the same process, injects the load DLLs with remote `LoadLibraryW`, resumes the new process, and exits the original process. Runtime DLL paths are resolved beside the proxy DLL.

For an install-style folder, DLS can rename the original DLL to the resolved `forward_to` path and copy the proxy beside it:

```bash
zig build -Dinput=C:\Game\Library.dll -Dload=Patch.dll -Dcopy_to_input_dir=true
```

Example layout after install:

```text
Library.dll        <- generated proxy
Library.og.dll     <- original backing DLL
Patch.dll          <- DLL loaded by the proxy
```

To output a pair without changing the input folder:

```bash
zig build -Dinput=C:\Game\Library.dll -Dload=Patch.dll -Doutput_pair=true
```

This writes the proxy as `Library.dll` and the backing DLL as `Library.og.dll` in the build output. Add `-Dcopy_to=DIR` to put the pair somewhere else.

To fold the backing DLL and loaded DLLs into the generated proxy:

```bash
zig build -Dinput=C:\Game\Library.dll -Dload=Patch.dll -Dembed_dlls=true
```

This embeds `Library.og.dll` and each configured load DLL as raw bytes inside `Library.dll`. At runtime, the proxy extracts them into the current folder only when they are missing, then loads them normally. Use `config.zon` for multiple patch DLLs.

---

## Configuration

DLS reads `config.zon` beside `build.zig` by default. The file in this repo is the editable example and documents each option inline.

Main fields:

- `input`: DLL to read exports from
- `forward_to`: original DLL the proxy forwards to
- `output`: generated proxy DLL name
- `backend`: `runtime_stub` by default, or `pe_forwarder`
- `load`: DLLs loaded by the proxy
- `load_import`: import used by `pe_forwarder` to load DLLs
- `copy_to`: optional output copy directory
- `output_pair`: also output/copy the backing DLL beside the proxy
- `embed_dlls`: embed the backing DLL and loaded DLLs into the runtime stub
- `bootstrap`: restart through suspended-process injection when loaded DLLs are missing
- `forwarding`: export handling options

Use another config file:

```bash
zig build -Dconfig=some-file.zon
```

Override the backend:

```bash
zig build -Dbackend=runtime_stub
zig build -Dbackend=pe_forwarder
```

Enable pair, embedded output, or bootstrap from build options:

```bash
zig build -Doutput_pair=true
zig build -Dembed_dlls=true
zig build -Dbootstrap=true
```

Build options override config values:

```bash
zig build -Dinput=Library.dll -Dforward_to=Library.og.dll -Dload=Patch.dll
```

Useful build options:

- `-Dinput=[PATH]`
- `-Dforward_to=[PATH]`
- `-Doutput=[NAME]`
- `-Dbackend=runtime_stub|pe_forwarder`
- `-Dload=[PATH]`
- `-Dimport=[NAME_OR_ORDINAL]`
- `-Dcopy_to=[DIR]`
- `-Dcopy_to_input_dir=true`
- `-Doutput_pair=true|false`
- `-Dembed_dlls=true|false`
- `-Dbootstrap=true|false`

Use `config.zon` when you need multiple `load` entries.

---

## Backends

### `runtime_stub`

`runtime_stub` is the default backend.

It builds a normal DLL with real exported stubs. At runtime, the proxy loads configured DLLs with `LoadLibraryW`, loads the backing DLL with `LoadLibraryW`, resolves exports with `GetProcAddress`, then jumps to the resolved export.

When `embed_dlls` is enabled, this backend also embeds the backing DLL and configured loaded DLLs as raw bytes, extracts them into the current folder if they are missing, then continues through the same loading path.

When `bootstrap` is enabled, this backend restarts the current executable suspended and injects the configured load DLLs if they are not already loaded. This is useful when the loaded DLL needs the same startup shape as a launcher/injector.

This is the safer default when the host expects real exported functions from the proxy DLL.

### `pe_forwarder`

`pe_forwarder` emits a tiny PE forwarder DLL directly.

This mirrors the reference forwarder style: companion DLLs are loaded through the PE import table, while exports are represented as PE export forwarders to `forward_to`.

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
