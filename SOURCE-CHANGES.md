# Modifications to upstream sources

This distribution is built by skw398 from the sources pinned in `deps.txt`,
with the modifications described below. It is not an unmodified upstream
build. Notice updated: 2026-10-25. Dates below record when the modifications
were introduced or revised in this project's history, not the date on which
an individual CI build applies them.

The source archive keeps the original upstream archives unchanged. The
included build scripts reproduce these modifications. No source patches are
applied. Upstream copyright and license notices remain applicable to the
affected code.

## Conditional build-file changes

These transformations are maintained by skw398 and only change files when
their matching content is present. The exact rules are in the supplied scripts;
they apply to the pinned components, including their supplied subdirectories.

| Introduced / revised | Target | Transformation and implementation |
|---|---|---|
| 2026-09-27 / 2026-10-04 | `CMakeLists.txt` and `*.cmake` within the first five levels of fetched source directories | Remove bare `-Werror` options while retaining warning-specific options. Implemented by `fetch()` in `scripts/lib.sh`. |
| 2026-09-27 | `configure` in source directories using the `autotools` recipe | Remove the obsolete Darwin linker option `-force_cpusubtype_ALL`. Implemented by `build_generic()` in `scripts/build-deps.sh`. |
| 2026-09-27 | Generated `Makefile` files under source directories using the `autotools` recipe | Remove `-Werror` and `-Werror=<warning>` options after configure. Implemented by `build_generic()` in `scripts/build-deps.sh`. |
| 2026-09-27 | Autotools components without an executable `configure` | Run the upstream bootstrap script or `autoreconf -fi` to generate configuration files. Refresh timestamps on pre-generated Autotools files to prevent unwanted regeneration. Implemented by `build_generic()` in `scripts/build-deps.sh`. |

Compiler flags and other selected build options are recorded in
`scripts/data/build-deps.txt`, the build scripts and the packaged
`build-info/buildconf.txt`. Two of them compensate for toolchain changes rather
than modify files: a `size_t` preinclude passed through `CXXFLAGS` (newer libc++
no longer provides it transitively) and `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`
(CMake 4 with older projects). Both are set by `scripts/build-deps.sh`. Generated build outputs and installation metadata
are recreated by those scripts. `BUILDING.md` describes how to rebuild or
apply further modifications; `LICENSING.md` describes the license scope.
