import json,os,sys
from pathlib import Path
import cocotb
@cocotb.test()
async def runtime_probe(dut):
    result=dict(version=sys.version,executable=sys.executable,libpython_loc=os.environ.get('LIBPYTHON_LOC'))
    Path(os.environ['PBE_RUNTIME_PROBE_OUT']).write_text(json.dumps(result,indent=2)+'\n')
    dut._log.info('ACTUAL_RUNTIME %s',json.dumps(result))
