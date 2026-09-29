# Autonomous upstream D2K synchronization

Source: https://github.com/necronicle/d2k, branch feat/telegram-tunnel.

The project checks this branch every 15 minutes and records the last processed revision in .github/upstream-sync-state.

Upstream code is not blindly copied because the Hopper project has diverged architecturally. Known mechanical compatibility fixes may be applied automatically and are followed by the full local CI check. Unknown changes create a GitHub issue for targeted adaptation.

## Current MIPS fix

Upstream revision d86d00b5dbab9066384422159712c5b74335937e fixes C pipe() success handling for MIPS/MIPSel: failure is tested with < 0 rather than assuming every non-zero return is failure.

For Hopper, the adapter searches local C sources for the same unsafe pattern and normalizes it to < 0. If no equivalent code exists, no unrelated Hopper code is changed.

The upstream project reports QEMU MIPS/MIPSel regression coverage; that is upstream evidence and is not treated as a Hopper hardware test.

## Limits

GitHub scheduled workflows support intervals down to 5 minutes; this project uses 15 minutes. Scheduled workflows can still be delayed by GitHub load.
