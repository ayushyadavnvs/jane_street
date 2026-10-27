# Working on this repository

- Two living documents must be updated in the same change as the work they describe:
  - `docs/DESIGN_DECISIONS.md`: every design decision, its alternatives and why. When a new
    protocol forces a change, mark the old decision **Changed** and say which protocol caused it.
  - `docs/BUG_LOG.md`: every bug (design, test, tool), with the code before, the code after,
    and the test that fails before the fix and passes after.
- `pbe_v1/` (UART, SPI, I2C) and `pbe_v2/` (adds USB) are separate copies. A fix that applies
  to both goes into both.
- Run `make test` in both version folders before pushing; it must exit non-zero on any failure.
