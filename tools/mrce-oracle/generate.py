#!/usr/bin/env python3
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

"""Compile pinned Pascal caller methods and emit independent Swift test vectors."""
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


def source(checkout, name):
    # Read the immutable git object, never a possibly edited working tree.
    return subprocess.check_output(['git', '-C', str(checkout), 'show', f'{PIN}:{name}']).decode('utf-8-sig')


def method(text, name):
    matches = list(re.finditer(r'^(?:constructor|procedure|function) TDxOperator\.[A-Za-z]+\b', text, re.M))
    for i, match in enumerate(matches):
        if match.group().endswith('.' + name):
            end = matches[i + 1].start() if i + 1 < len(matches) else text.rfind('end.')
            # Trailing comments belong to the next method, and are harmless.
            return text[match.start():end]
    raise ValueError(f'Missing Pascal method: {name}')


def prepare(checkout, build, dynamic_call=False, conversations=False):
    original = source(checkout, 'DxOper.pas')
    station = source(checkout, 'Station.pas')
    # Keep the original class declaration, exposing private fields only to the runner.
    declaration = original[original.index('const\n'):original.index('function ToStr(')]
    declaration = declaration.replace('  private\n', '  public\n')
    for name in ['GetSendDelay', 'GetReplyTimeout', 'GetWpm', 'GetNR', 'GetName', 'IsMyCall']:
        declaration, count = re.subn(r'    function ' + name + r'\b[^\n]*(?:\n      [^\n]*)*\n', '', declaration)
        if count != 1:
            raise ValueError(f'Declaration extraction failed: {name}')
    names = ['Create', 'IsGhosting', 'GetSkillLevel', 'DecPatience', 'MorePatience', 'SetState', 'MsgReceived', 'GetReply']
    bodies = '\n'.join(method(original, name) for name in names)
    # Matching/arbitration is an explicit input boundary, not a second implementation.
    boundaries = '''
function TDxOperator.CallConfidenceCheck(const ACall: string; ARandomResult: boolean): TCallCheckResult;
begin Result := TCallCheckResult(MatchResult); end;
function TDxOperator.IsActiveInQso: Boolean;
begin Result := ActiveCaller; end;
'''
    license_header = original[:original.index('unit DxOper;')]
    unit = license_header + '''unit DxOper;
{$mode delphi}{$H+}{$B-}
interface
uses OracleSupport;
''' + declaration + '\nimplementation\nuses Math, SysUtils;\n' + bodies + boundaries + '\nend.\n'
    # Qualified Ini values used by these methods become support-unit globals.
    unit = unit.replace('Ini.Lids', 'Lids')
    if not dynamic_call:
        unit = unit.replace('Tst.Me.HisCall', "'K1AB'")
    (build / 'DxOper.pas').write_text(unit)
    enums = re.search(r'  TStationMessage =.*?TStationMessages = set of TStationMessage;', station, re.S).group()
    rnd = source(checkout, 'RndFunc.pas')
    rayleigh = re.search(r'function RndRayleigh\(AMean: Single\): Single;\s*begin.*?end;', rnd, re.S).group()
    support_text = (HERE / 'OracleSupport.pas').read_text()
    contest = source(checkout, 'Contest.pas')
    def contest_method(name):
        start = contest.index('procedure TContest.' + name)
        end = contest.index('\nend;', start) + len('\nend;')
        return contest[start:end]
    support_text = support_text.replace('{CONTEST_METHODS}', contest_method('OnExchangeEditComplete') + '\n' + contest_method('SetHisCall'))
    support_text = support_text.replace('Log.CallSent', 'CallSent')
    support = (license_header + support_text
               .replace('{STATION_MESSAGES}', enums).replace('{RAYLEIGH_IMPLEMENTATION}', rayleigh))
    (build / 'OracleSupport.pas').write_text(support)
    if conversations:
        main = source(checkout, 'Main.pas')
        start = main.index('  //no QSO in progress, send CQ')
        end = main.index('\nend;', start) + len('\nend;')
        body = main[start:end]
        if body.count('SendMsg(') < 5 or 'Tst.OnExchangeEditComplete' not in body:
            raise ValueError('Pinned Main.ProcessEnter extraction did not match expected block')
        body = re.sub(r'\bEdit([123])\.Text', r'Mainform.Edit\1.Text', body)
        body = body.replace('Mainform.Mainform.', 'Mainform.')
        body = re.sub(r'    // special case - Cursor.*?      MustAdvance := true;\n', '', body, flags=re.S)
        body = body.replace('(RunMode <> rmStop) and', 'True and')
        body = body.rsplit('\nend;', 1)[0]
        template = (HERE / 'conversation_runner.pas').read_text()
        template = template.replace('{PROCESS_ENTER_BODY}', body)
        contest = source(checkout, 'Contest.pas')
        send_start = contest.index('procedure TContest.SendMsg(')
        send_end = contest.index('\nend;', send_start) + len('\nend;')
        send = contest[send_start:send_end]
        templates = re.findall(r"(msg\w+):\s*SendText\(AStn, '([^']*)'\)", send)
        cases = '\n'.join(f"    {enum}: Result := '{value}';" for enum, value in templates)
        template = template.replace('{TEMPLATE_CASES}', cases)
        (build / 'conversation_runner.pas').write_text(template)
        runner_name = 'conversation_runner'
    else:
        (build / 'runner.pas').write_text((HERE / 'runner.pas').read_text())
        runner_name = 'runner'
    (build / 'LICENSE.md').write_text(source(checkout, 'LICENSE.md'))
    subprocess.run(['fpc', '-Mdelphi', '-B', '-o' + str(build / runner_name), str(build / (runner_name + '.pas'))], cwd=build, check=True)
    return hashlib.sha256(original.encode()).hexdigest()


def cases():
    states = ['needPrevEnd', 'needQso', 'needNr', 'needCall', 'needCallNr', 'needEnd', 'done', 'failed']
    # Include thresholds on either side; avoid conflating Pascal Single vs Swift Double boundaries.
    for state in states:
        for mode in ['pileup', 'single', 'hst']:
            for contest in ['wpx', 'sweepstakes']:
                for lids in [False, True]:
                    for patience in [0, 1, 3, 4, 5]:
                        for style in [0.05, 0.20, 0.40, 0.70, 0.85, 0.90, 0.97]:
                            for counter in [0, 1, 2, 3]:
                                for draw in [0.1, 0.5, 0.95]:
                                    yield dict(action='reply', state=state, mode=mode, contest=contest,
                                               lids=lids, patience=patience, style=style, counter=counter, draw=draw)
    for state in states[1:6]:
        for mode in ['pileup', 'single', 'hst']:
            for patience in [0, 1, 2, 5]:
                for silence in [0, 1, 2, 3]:
                    for stays in [False, True]:
                        yield dict(action='patience', state=state, mode=mode, patience=patience,
                                   silence=silence, stays=stays, draw=0.5)
    # Run real production transition integration. Single/HST guarantee exchange acceptance.
    for state in states[:6]:
        for mode in ['single', 'hst']:
            for message in ['cq', 'nil', 'b4', 'tu', 'question', 'garbage', 'mycall', 'number-question', 'call', 'exchange', 'call-exchange']:
                for match in [0, 60, 100]:
                    for active in [False, True]:
                        for corrected in [False, True]:
                            yield dict(action='transition', state=state, mode=mode, message=message,
                                       match=match, active=active, corrected=corrected, patience=5,
                                       incomplete=2, counter=2, draw=0.5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, default=ROOT / '.upstream/MorseRunner')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--conversations', action='store_true', help='generate compact end-to-end conversation fixtures')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='mrce-oracle-') as temp:
        build = Path(temp)
        digest = prepare(args.upstream, build, dynamic_call=args.conversations, conversations=args.conversations)
        if args.conversations:
            def enter(label, call, valid, match):
                return dict(label=label, input=dict(command='Enter',call=call,validCall=valid,match=match,exchange1='',exchange2=''))
            prefix = [dict(label='CQ',input=dict(command='CQ',call='',validCall=False,match=0,exchange1='',exchange2='')),
                      enter('partial-1','K1AB?',False,80), enter('partial-2','K1A?',False,60)]
            scenarios = [
                ('final-correct', prefix + [enter('final','K1ABC',True,100)]),
                ('final-wildcard', prefix + [enter('wildcard','K1AB?',False,80)]),
                ('final-valid-inexact', prefix + [enter('valid-inexact','K1AB',True,60)]),
            ]
            inputs = [dict(caller='K1ABC', own='VE3NEA', ownExchange='5NN 001', callerExchange='599 001', style=0.7, draw=0.5,
                           steps=[s['input'] for s in steps]) for _, steps in scenarios]
            run = subprocess.run([str(build / 'conversation_runner')], input=''.join(json.dumps(x)+'\n' for x in inputs), text=True, capture_output=True, check=True)
            outputs = [json.loads(line) for line in run.stdout.splitlines()]
            if len(outputs) != len(inputs) or any(len(o.get('steps', [])) != len(s) for o, (_, s) in zip(outputs, scenarios)):
                raise RuntimeError('Conversation oracle response count mismatch')
            source_hashes = {name: hashlib.sha256(source(args.upstream, name).encode()).hexdigest() for name in ['DxOper.pas','Main.pas','Contest.pas','RndFunc.pas','Station.pas']}
            document = dict(provenance=dict(upstream=PIN, sourceSHA256=source_hashes, compiler=subprocess.check_output(['fpc','-iV'],text=True).strip(),
                                             target=subprocess.check_output(['fpc','-iTP','-iTO'],text=True).split(), regenerate='python3 tools/mrce-oracle/generate.py --conversations --output Tests/MorseJoggerCoreTests/MRCEConversationFixtures.json'),
                            scenarios=[dict(name=name, settings=dict(contest='wpx',mode='single',seed=172,caller='K1ABC',styleBand=0.7,pascalDraw=0.5,ownExchange='5NN 001',callerExchange='599 001'),
                                             steps=[dict(label=steps[i]['label'],input=steps[i]['input'],oracle={k:v for k,v in output.items() if k not in ('call','messages','state')} | dict(messages=output['messages'],state=output['state'])) for i,output in enumerate(response['steps'])])
                                      for (name,steps),response in zip(scenarios,outputs)])
            args.output.write_text(json.dumps(document, indent=2)+'\n')
            print(f'Wrote {len(scenarios)} Pascal conversation scenarios to {args.output}')
            return
        inputs = list(cases())
        run = subprocess.run([str(build / 'runner')], input=''.join(json.dumps(c) + '\n' for c in inputs),
                             text=True, capture_output=True, check=True)
        outputs = [json.loads(line) for line in run.stdout.splitlines()]
        if len(outputs) != len(inputs):
            raise RuntimeError('Oracle response count mismatch')
        document = dict(upstream=PIN, sourceSHA256=digest,
                        compiler=subprocess.check_output(['fpc', '-iV'], text=True).strip(),
                        target=subprocess.check_output(['fpc', '-iTP', '-iTO'], text=True).split(),
                        cases=[dict(input=i, expected=o) for i, o in zip(inputs, outputs)])
        args.output.write_text(json.dumps(document, separators=(',', ':')) + '\n')
        print(f'Wrote {len(inputs)} compiled-Pascal comparisons to {args.output}')


if __name__ == '__main__':
    main()
