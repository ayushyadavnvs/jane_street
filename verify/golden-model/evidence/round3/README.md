# Round-3 evidence

The report is [REPORT.md](../../REPORT.md#round-3--d89d94-ethernet-verification).
Results are intentionally mixed: successful checks, expected historical counterexamples,
initial verification failures, and the open receiver jitter defect. Nonzero is not a pass.

- `stage1/`: original/default campaigns, exact CRC/stress comparisons, bus XML, versions,
  suite download SHA, decoder and harness failures, and the pre-CAN PAGE counterexample.
- `model/`: default JSON equality against untouched feature/ethernet, model timing pilot,
  failed first large-campaign source manifest and global-index replay evidence. Final large
  results identify simulator, seed range, actual clocks and all source/test input hashes.
- `formal/`: source/configuration-validated original baseline jobs, repaired-source Ethernet,
  pre-CAN and D88 engine checks, and successful legacy/repair-only line equivalence receipts.
  Expected assertion failures, bounded passes, covers and induction are separate categories.
- `vectors/`: independent wide/narrow catalogue receipts, actual decoded Ethernet pcap,
  external wire observations and input hashes. Pcap omits FCS; its sidecar carries FCS/timing.
- `coverage/`: default and extended counts, named-bin conditions and simulator run receipts.
  The last directed rerun closes two bins; it is recorded separately from the first campaign.
- `mutations/`: original/final mutation observations, initial survivors/inconclusives, final
  single-site faults and frozen input manifests/source archives. A timeout/compile error is
  never called a kill. The final full campaign has an immutable baseline archive.
- `stress/`: complete digital timing observations, actual failing edge/payload stimuli,
  the minimum-frame reproducer in both simulators, and error/recovery results. Required
  ±13.5-ns failures remain failures; error flags do not imply successful payload delivery.
- `integration/`: final regression/model/guard, race-check and exact lint receipts.

The baseline is feature/ethernet `3cca934`. The only actual RTL edit is the Manchester
idle-wait guard. The old 112 non-default formal jobs are verified against original RTL in
an isolated worktree, not mislabeled as repaired-source solver runs. New-source SBY jobs
and unbounded repair equivalence establish the stated additional results. An earlier fixed
worktree used the same guard with a different comment; its pilot receipts retain their own
hashes. The final Ethernet block is also run against the actual main working-tree source.

An attempted broad structural engine proof left 35 cells unproved; its log is retained as
incomplete evidence, not a proof. The successful D88 engine comparison is bounded to eight.
Old historical evidence directories are untouched. Annotated source, executables and complete
build trees remain in ignored `pbe_v1/build/`; the report identifies residual structural gaps.
No physical/gate-level workflow or external account message is part of these receipts.
