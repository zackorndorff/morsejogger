//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
program runner;
{$mode delphi}{$H+}{$B-}
uses SysUtils, TypInfo, fpjson, jsonparser, OracleSupport, DxOper;
var
  Line, Action, MessageName, StateName: string;
  Request, Output: TJSONObject;
  Op: TDxOperator;
  Reply: TStationMessage;
  Messages: TStationMessages;
begin
  while not EOF do
  begin
    ReadLn(Line);
    Request := GetJSON(Line) as TJSONObject;
    try
      Action := Request.Get('action', '');
      RunMode := rmPileup;
      if Request.Get('mode', '') = 'single' then RunMode := rmSingle;
      if Request.Get('mode', '') = 'hst' then RunMode := rmHst;
      SimContest := scWpx;
      if Request.Get('contest', '') = 'sweepstakes' then SimContest := scArrlSS;
      Lids := Request.Get('lids', False);
      Stay := Request.Get('stays', False);
      ActiveCaller := Request.Get('active', True);
      MatchResult := 0;
      if Request.Get('match', 0) = 100 then MatchResult := 1
      else if Request.Get('match', 0) > 0 then MatchResult := 2;
      Draw := Request.Get('draw', 0.5);
      Op := TDxOperator.Create('K1ABC', osDone);
      try
        StateName := 'os' + Request.Get('state', 'needQso');
        Op.State := TOperatorState(GetEnumValue(TypeInfo(TOperatorState), StateName));
        Op.Patience := Request.Get('patience', 5);
        Op.R2 := Request.Get('style', 0.5);
        Op.Skills := 2;
        Op.FSilentTimeoutCount := Request.Get('silence', 0);
        Op.FIncompleteCallCount := Request.Get('incomplete', 0);
        Op.SendNrQmCnt := Request.Get('counter', 0);
        Op.CorrectedCallAndExchSent := Request.Get('corrected', False);
        DrawCount := 0;
        Reply := msgNone;
        if Action = 'reply' then Reply := Op.GetReply
        else if Action = 'patience' then Op.MsgReceived([msgNone])
        else if Action = 'transition' then
        begin
          MessageName := Request.Get('message', '');
          Messages := [];
          if MessageName = 'cq' then Messages := [msgCQ];
          if MessageName = 'nil' then Messages := [msgNil];
          if MessageName = 'b4' then Messages := [msgB4];
          if MessageName = 'tu' then Messages := [msgTU];
          if MessageName = 'question' then Messages := [msgQm];
          if MessageName = 'garbage' then Messages := [msgGarbage];
          if MessageName = 'mycall' then Messages := [msgMyCall];
          if MessageName = 'number-question' then Messages := [msgNrQm];
          if MessageName = 'call' then Messages := [msgHisCall];
          if MessageName = 'exchange' then Messages := [msgNR];
          if MessageName = 'call-exchange' then Messages := [msgHisCall, msgNR];
          Mainform.Edit1.Text := '';
          Op.MsgReceived(Messages);
        end
        else raise Exception.Create('Unknown oracle action');
        Output := TJSONObject.Create;
        try
          StateName := GetEnumName(TypeInfo(TOperatorState), Ord(Op.State));
          Delete(StateName, 1, 2);
          StateName[1] := LowerCase(StateName[1]);
          Output.Add('state', StateName);
          Output.Add('patience', Op.Patience);
          Output.Add('silence', Op.FSilentTimeoutCount);
          Output.Add('incomplete', Op.FIncompleteCallCount);
          Output.Add('counter', Op.SendNrQmCnt);
          Output.Add('corrected', Op.CorrectedCallAndExchSent);
          Output.Add('reply', GetEnumName(TypeInfo(TStationMessage), Ord(Reply)));
          Output.Add('draws', DrawCount);
          WriteLn(Output.AsJSON);
        finally Output.Free; end;
      finally Op.Free; end;
    finally Request.Free; end;
  end;
end.
