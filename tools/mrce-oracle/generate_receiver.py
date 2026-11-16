#!/usr/bin/env python3
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

"""Compile MRCE's receiver filter, modulator and AGC and emit level vectors."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

PIN = '304e51aece5a17f4cba548527816a385a8f6f814'
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
UNITS = ['VCL/MovAvg.pas', 'VCL/Mixers.pas', 'VCL/VolumCtl.pas']
CASES = [(500, 600), (250, 600), (100, 450), (600, 800), (350, 500), (150, 700)]
# The units are Delphi components. Their code is compiled as it is; only the
# Windows GUI units they list but do not use here are dropped from `uses`.
GUI = re.compile(r'\b(Windows|Messages|Graphics|Controls|Forms|Dialogs),\s*')
SND_TYPES = '''unit SndTypes;
{$mode delphi}
interface
const
  TWO_PI = 2 * Pi;
type
  TSingleArray = array of Single;
  TComplex = record Re, Im: Single; end;
  TComplexArray = array of TComplex;
  TReImArrays = record Re, Im: TSingleArray; end;
procedure SetLengthReIm(var Arr: TReImArrays; Len: integer);
procedure ClearReIm(var Arr: TReImArrays);
implementation
procedure SetLengthReIm(var Arr: TReImArrays; Len: integer);
begin
  SetLength(Arr.Re, Len);
  SetLength(Arr.Im, Len);
end;
procedure ClearReIm(var Arr: TReImArrays);
begin
  Arr.Re := nil; Arr.Im := nil;
end;
end.
'''


def source(checkout, name):
    return subprocess.check_output(['git', '-C', str(checkout), 'show', f'{PIN}:{name}']).decode('utf-8-sig')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, default=ROOT / '.upstream/MorseRunner')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    runner = (HERE / 'receiver_runner.pas').read_text()
    with tempfile.TemporaryDirectory(prefix='mrce-receiver-') as temp:
        build = Path(temp)
        hashes = {}
        for unit in UNITS:
            text = source(args.upstream, unit)
            hashes[unit] = hashlib.sha256(text.encode()).hexdigest()
            (build / Path(unit).name).write_text(GUI.sub('', text))
        # Same declarations as VCL/SndTypes.pas, without its Windows wave types.
        (build / 'SndTypes.pas').write_text(SND_TYPES)
        (build / 'receiver_runner.pas').write_text(runner)
        subprocess.run(['fpc', '-Mdelphi', '-B', '-oreceiver_runner', 'receiver_runner.pas'], cwd=build, check=True,
                       stdout=subprocess.DEVNULL)
        run = subprocess.run([str(build / 'receiver_runner')], input=''.join(f'{b} {p}\n' for b, p in CASES),
                             text=True, capture_output=True, check=True)
    cases = [json.loads(line) for line in run.stdout.splitlines()]
    if len(cases) != len(CASES):
        raise RuntimeError('Receiver oracle response count mismatch')
    tones = [dict(offset=float(o), amplitude=float(a), firstBlock=int(f), lastBlock=int(l)) for o, a, f, l in
             re.findall(r'\(Offset:\s*(-?\d+); Amplitude:\s*(\d+); FirstBlock:\s*(\d+); LastBlock:\s*(\d+)\)', runner)]
    document = dict(upstream=PIN, sourceSHA256=hashes, sampleRate=11025, blockSamples=512,
                    blocks=int(re.search(r'BLOCKS = (\d+)', runner).group(1)),
                    windowBlocks=int(re.search(r'WINDOW = (\d+)', runner).group(1)),
                    seed=int(re.search(r'Seed := (\d+)', runner).group(1)), tones=tones,
                    compiler=subprocess.check_output(['fpc', '-iV'], text=True).strip(),
                    regenerate='python3 tools/mrce-oracle/generate_receiver.py --output Tests/MorseJoggerCoreTests/MRCEReceiverFixtures.json',
                    cases=cases)
    args.output.write_text(json.dumps(document, separators=(',', ':')) + '\n')
    print(f'Wrote {len(cases)} compiled-Pascal receiver vectors to {args.output}')


if __name__ == '__main__':
    main()
