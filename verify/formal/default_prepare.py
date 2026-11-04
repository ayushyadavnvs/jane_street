#!/usr/bin/env python3
"""The default block uses the files bsync_prepare.py makes."""
import runpy, pathlib
runpy.run_path(str(pathlib.Path(__file__).with_name("bsync_prepare.py")), run_name="__main__")
