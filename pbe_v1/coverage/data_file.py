"""Coverage artifact enforcement shared by all Verilator entry points."""
from pathlib import Path


def clear_coverage(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)


def require_coverage(path):
    path = Path(path)
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f'Simulator did not produce fresh nonempty coverage data: {path}')
    return path.stat().st_size
