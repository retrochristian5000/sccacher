# WHP Clang++ precompiled-header caching

## Supported boundary

The WHP fork caches **C++ object files that consume an existing Clang PCH**.
It does **not** cache PCH creation.  A CMake/LLVM rule using
`-Xclang -emit-pch`, or a direct `-x c++-header` invocation, is passed
through to the compiler rather than treating an AST image as an ordinary
preprocessed object.

Clang++ consumers using either `-include-pch <path>` or the CMake spelling
`-Xclang -include-pch -Xclang <path>` must hash the **actual PCH file
contents** in addition to compiler identity, arguments, preprocessing output,
and relevant environment.  Clang's `-E` output by itself does **not** describe
all macro and AST state loaded from the PCH.  The preprocessor/direct cache
key must incorporate the PCH digest as well.

When a header, macro, or target ABI changes, the PCH producer must rebuild
first (via ordinary build dependencies); an unchanged consumer may then
reuse only an object cached against the corresponding PCH contents.
A fresh PCH is not evidence that the object cache should hit.

## LLVM CMake smoke tests

Run `tests/integration/scripts/test-clang.sh` in the existing integration
environment with the current fork binary. The Clang cases verify:

* an implicit `-x c++-header` PCH producer still produces a real PCH;
* the same C++ PCH consumer produces an **actual cache hit** on recompilation;
* changing only the PCH bytes invalidates the cached object (including
  inline AST/macro values not representable by source text alone);
* the new PCH content becomes cacheable on a subsequent unchanged consumer;
* changing a consumer-side `-D` macro changes the result;
* CMake's `-Xclang -emit-pch` producer and `-Xclang -include-pch`
  consumer spellings work together.

Clang 17 and Apple Clang commonly require
`-Xclang -fno-pch-timestamp` rather than passing
`-fno-pch-timestamp` as a top-level driver argument.
The integration test uses the cc1 spelling.

## Deliberately unsupported

Caching PCH **producers** requires independently validating every transitive
header, include search result, compiler option, macro, plugin, diagnostic
artifact, serialized AST dependency, and host/compiler identity.  The
existing C/C++ object hash based on `-E` cannot be used as proof of
correctness for a PCH output.  Do not remove the producer bypass, mark
unrecognized PCH flags cacheable, or claim producer cache-hit support
without such a dedicated validation design.

The managed QEMU bootstrap is allowed to launch C++ compilation through
this fork when LLVM PCH is enabled; a system sccache is not automatically
granted the same admission.  Runtime cache hits and native LLVM/LLDB builds
still require execution on the target host.
