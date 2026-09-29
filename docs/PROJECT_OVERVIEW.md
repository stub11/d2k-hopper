# D2K Hopper — Project Overview

## Purpose

D2K Hopper is Dynamic2Keenetic (d2k), a research/prototyping project for traffic-path transformations on Keenetic-class routers. The repository contains a Go control/catalog/probing layer (d2k) and a C datapath (d2kd).

The repository documentation describes staged development around traffic observation, transformation experiments, DPI detection/model catalog work, scheduling, and installation. Features that are not implemented or verified must not be treated as production-ready.

## Target platform

The project documentation targets Keenetic Hopper / KN-3810-class hardware, with an aarch64 userspace and a 4.9 NDM kernel environment. The exact runtime environment must be validated on the target device before deployment.

## Build layout

- Go control plane: repository Go sources and go.mod.
- C datapath: datapath/.
- Build helper: scripts/build.sh.
- Local verification gate: scripts/check.sh.
- Router-related helpers/configuration: scripts/, config/, docs/.

The Go module currently requires Go 1.25.12.

## Architectures

scripts/build.sh is designed to produce Go builds for multiple architectures, including arm64, arm, amd64, mips, mipsle, mips64le, ppc64, riscv64, and 386. The exact supported runtime targets should be confirmed against current CI and release configuration before publishing binaries.

## Verification status

CI and repository tests are the source of truth for build/test claims. Successful compilation or static checks do not prove behavior on real Keenetic hardware.

The project has historical documentation describing prior hardware validation; this current audit does not itself reproduce a real-device test.

## Hopper 3810 helper files

The previous one-time apply-hopper-patch.yml workflow generated four helper files by overwriting them on pushes. That workflow has been removed from the audit branch because it could overwrite manual changes.

The helper scripts/configuration still require review and validation against the actual project architecture before being considered production-ready.
