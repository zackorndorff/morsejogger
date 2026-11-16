#!/usr/bin/env python3
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

"""Compile the pinned MRCE keyers and emit element-timing vectors for Swift tests."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

PIN = '304e51aece5a17f4cba548527816a385a8f6f814'
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
UNITS = ['VCL/MorseKey.pas', 'VCL/FarnsKeyer.pas', 'VCL/MorseTbl.pas']
RAMP = 149  # Round(2.7 * 0.005 * 11025): every keyed element carries one ramp-off tail.


def source(checkout, name):
    return subprocess.check_output(['git', '-C', str(checkout), 'show', f'{PIN}:{name}']).decode('utf-8-sig')


def cases():
    plain = ['E', 'T', 'PARIS', 'CQ VE3NEA TEST', 'K7S', '5NN TT1', 'R 599 001', 'DE W1AW/3 599 12',
             '?', 'TU', 'NR?', 'QRL?   QRL?', 'VE3NEA  QSY QSY', 'BOB  1234']
    for text in plain:
        for wpm in [12, 15, 18, 20, 22, 25, 28, 30, 33, 35, 40, 45, 50, 60]:
            yield dict(keyer='std', text=text, wpmS=wpm, wpmC=wpm)
    # Faster 5NN: Station.SendText wraps the report in WPM_PER_STEP=1 markers.
    for wpm in [18, 20, 25, 30, 35, 40]:
        for rate in [1.2, 1.3, 1.4, 1.5]:
            steps = round(wpm * rate - wpm)
            fast = '<' * steps + '5NN' + '>' * steps
            for text in [fast + ' 001', 'K1ABC ' + fast + ' TT1', 'R ' + fast + ' 12 ' + fast + ' 12']:
                yield dict(keyer='std', text=text, wpmS=wpm, wpmC=wpm, fastSteps=steps)
    for text in ['E', 'PARIS', 'CQ SST VE3NEA', 'K7S', 'BOB MA', 'R GM BOB MA', 'TU VE3NEA', 'NAME?', 'BOB  MA']:
        for wpm_s, wpm_c in [(10, 25), (15, 25), (18, 20), (20, 25), (22, 25), (25, 25), (15, 18), (30, 25), (35, 25)]:
            yield dict(keyer='farns', text=text, wpmS=wpm_s, wpmC=wpm_c)


def describe(case):
    """Plain text and report offsets in the single-spaced message Swift indexes."""
    text, plain, starts = case['text'], '', []
    for i, ch in enumerate(text):
        if ch == '<' and (i == 0 or text[i - 1] != '<'):
            starts.append(len(' '.join(plain.split())) + (1 if plain.endswith(' ') else 0))
        if ch not in '<>':
            plain += ch
    return plain, starts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, default=ROOT / '.upstream/MorseRunner')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='mrce-keyer-') as temp:
        build = Path(temp)
        hashes = {}
        for unit in UNITS:
            text = source(args.upstream, unit)
            hashes[unit] = hashlib.sha256(text.encode()).hexdigest()
            (build / Path(unit).name).write_text(text)
        # The keyers only need the sample array type from the Windows audio unit.
        (build / 'SndTypes.pas').write_text(
            'unit SndTypes;\n{$mode delphi}\ninterface\ntype TSingleArray = array of Single;\nimplementation\nend.\n')
        (build / 'keyer_runner.pas').write_text((HERE / 'keyer_runner.pas').read_text())
        subprocess.run(['fpc', '-Mdelphi', '-B', '-okeyer_runner', 'keyer_runner.pas'], cwd=build, check=True,
                       stdout=subprocess.DEVNULL)
        inputs = list(cases())
        run = subprocess.run([str(build / 'keyer_runner')], input=''.join(json.dumps(c) + '\n' for c in inputs),
                             text=True, capture_output=True, check=True)
        outputs = [json.loads(line) for line in run.stdout.splitlines()]
        if len(outputs) != len(inputs):
            raise RuntimeError('Keyer oracle response count mismatch')
        vectors = []
        for case, out in zip(inputs, outputs):
            plain, starts = describe(case)
            vectors.append(dict(keyer=case['keyer'], text=plain, wpmS=case['wpmS'], wpmC=case['wpmC'],
                                fastSteps=case.get('fastSteps', 0), fastStarts=starts, samples=out['len'],
                                marks=[[start, length - RAMP] for start, length in out['marks']]))
        document = dict(upstream=PIN, sourceSHA256=hashes, sampleRate=11025,
                        compiler=subprocess.check_output(['fpc', '-iV'], text=True).strip(),
                        regenerate='python3 tools/mrce-oracle/generate_keyer.py --output Tests/MorseJoggerCoreTests/MRCEKeyerFixtures.json',
                        cases=vectors)
        args.output.write_text(json.dumps(document, separators=(',', ':')) + '\n')
        print(f'Wrote {len(vectors)} compiled-Pascal keyer vectors to {args.output}')


if __name__ == '__main__':
    main()
