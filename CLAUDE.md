# Working on this repository

- Two living documents must be updated in the same change as the work they describe:
  - `docs/DESIGN_DECISIONS.md`: every design decision, its alternatives and why. When a new
    protocol forces a change, mark the old decision **Changed** and say which protocol caused it.
  - `docs/BUG_LOG.md`: every bug (design, test, tool), with the code before, the code after,
    and the test that fails before the fix and passes after.
- `pbe_v1/` is the design. v2 (USB) is retired: its code is on the branch `archive/v2-usb`
  and its lessons are in `docs/USB_NOTES.md`. Keep the engine general: new hardware should be
  useful to more than one protocol.
- Run `make test` in `pbe_v1/` before pushing; it must exit non-zero on any failure.
