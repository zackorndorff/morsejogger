#!/usr/bin/env python3
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

"""Compile the pinned CallsignUtils.ExtractPrefix and emit WPX prefix vectors."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

PIN = '304e51aece5a17f4cba548527816a385a8f6f814'
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent

CALLS = '''K1ABC W1AW N7HPT AA1A KX7FUR WB6ACK KC5ARZ VE3NEA VA7XX VO1AA VY2TT
DL1ABC DA0HQ G3ABC M0XYZ 2E0ABC F5XYZ I1ZA IK2ABC EA0U EA8AB JA4BKS 7J1AAA JH1XYZ
ZL2M VK3ABC PY4E PY2AVE LU1ABC YU6E YU6HAW 9A1A S51A OK1ABC OM3XX SP9ABC HB9ABC
OE1XYZ ON4UN PA3ABC SM5XYZ OH2BH LZ1ABC YO3XX UA3ABC R3A RC2FX 4X6TT 3DA0RU
8P6ABC 9V1YC A61AA A71BX B1A BY1AA C6AAA D4C E73A K7S W8LNS AB3W KO4HD WG2MS
W1AW/3 W1AW/KH6 KH6/W1AW DL1ABC/P G3ABC/M K1ABC/MM VE3NEA/QRP DL/K1ABC K1ABC/DL
F/G3ABC 9A/DL1ABC 3/K1ABC K1ABC/3 EA8/DL1ABC/P VP2E/K1ABC K1ABC/VP2E KH6ABC KL7XX
KP4AA KP2M XE1ABC XE2/K1ABC 4U1ITU 4U1UN HK0ABC TI9A VP8ABC ZS6ABC 5B4ABC A1 K1
W K1A 9A A9A LX1NO OZ1ABC CT1ABC CU3AA GM3ABC GW4ABC EI3ABC TF3ABC JW5E R1FJ
UA9ABC UN7AB BA1AA BV1AB HL1ABC DU1ABC YB0ABC VU2ABC 9M2AB HS0ZAA ZS1/DL1ABC'''.split()


def source(checkout, name):
    return subprocess.check_output(['git', '-C', str(checkout), 'show', f'{PIN}:{name}']).decode('utf-8-sig')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, default=ROOT / '.upstream/MorseRunner')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    unit = source(args.upstream, 'Util/CallsignUtils.pas')
    start = unit.index('function ExtractPrefix(Call: string; DeleteTrailingLetters: boolean): string;')
    body = unit[start:unit.index('function IsValidCall(Call: string): boolean;', start)]
    with tempfile.TemporaryDirectory(prefix='mrce-prefix-') as temp:
        build = Path(temp)
        (build / 'prefix_runner.pas').write_text((HERE / 'prefix_runner.pas').read_text().replace('{EXTRACT_PREFIX}', body))
        subprocess.run(['fpc', '-Mdelphi', '-B', '-oprefix_runner', 'prefix_runner.pas'], cwd=build, check=True,
                       stdout=subprocess.DEVNULL)
        run = subprocess.run([str(build / 'prefix_runner')], input='\n'.join(CALLS) + '\n', text=True,
                             capture_output=True, check=True)
    cases = []
    for line in run.stdout.splitlines():
        call, _, prefix = line.partition(' ')
        cases.append(dict(call=call, prefix=prefix))
    if len(cases) != len(CALLS):
        raise RuntimeError('Prefix oracle response count mismatch')
    document = dict(upstream=PIN, sourceSHA256=hashlib.sha256(unit.encode()).hexdigest(),
                    compiler=subprocess.check_output(['fpc', '-iV'], text=True).strip(),
                    regenerate='python3 tools/mrce-oracle/generate_prefix.py --output Tests/MorseJoggerCoreTests/MRCEPrefixFixtures.json',
                    cases=cases)
    args.output.write_text(json.dumps(document, indent=1) + '\n')
    print(f'Wrote {len(cases)} compiled-Pascal prefix vectors to {args.output}')


if __name__ == '__main__':
    main()
