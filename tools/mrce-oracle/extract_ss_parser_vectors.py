#!/usr/bin/env python3
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

"""Extract MRCE's own Sweepstakes exchange-parser test cases as Swift fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

PIN = '304e51aece5a17f4cba548527816a385a8f6f814'
ROOT = Path(__file__).resolve().parents[2]
NAME = 'Test/SSExchParserTest.pas'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, default=ROOT / '.upstream/MorseRunner')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    text = subprocess.check_output(['git', '-C', str(args.upstream), 'show', f'{PIN}:{NAME}']).decode('utf-8-sig')
    cases = []
    # Only the cases attached to RunTest, which states the parsed fields:
    # '<entered>, <NR>.<Prec>.<Check>.<Section>[.<Call>][-<error>]'
    body = text[:text.index('procedure RunTest(')]
    for line in body.splitlines():
        if line.lstrip().startswith('//'):
            continue
        match = re.search(r"\[TestCase\('([^']+)',\s*'([^']*)'\)\]", line)
        if not match:
            continue
        entered, _, expected = match.group(2).partition(',')
        expected = expected.strip()
        summary, _, error = expected.partition('-')
        parts = summary.split('.')
        if len(parts) < 4:
            continue
        cases.append(dict(name=match.group(1), entered=entered.strip(), serial=int(parts[0]), precedence=parts[1],
                          check=parts[2], section=parts[3], call='.'.join(parts[4:]), error=error))
    document = dict(upstream=PIN, source=NAME, sourceSHA256=hashlib.sha256(text.encode()).hexdigest(),
                    regenerate='python3 tools/mrce-oracle/extract_ss_parser_vectors.py --output Tests/MorseJoggerCoreTests/MRCESweepstakesParserFixtures.json',
                    cases=cases)
    args.output.write_text(json.dumps(document, indent=1) + '\n')
    print(f'Wrote {len(cases)} Sweepstakes parser cases to {args.output}')


if __name__ == '__main__':
    main()
