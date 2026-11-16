//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
program conversation_runner;
{$mode delphi}{$H+}{$B-}
uses SysUtils, TypInfo, fpjson, jsonparser, OracleSupport, DxOper;
var
  Line, CallerCall, OwnCall, OwnExchange, CallerExchange, UserTx, RxText, ErrorText: string;
  Request, StepRequest, Output, StepOutput: TJSONObject;
  Steps, StepOutputs, MessageList: TJSONArray;
  Op: TDxOperator;
  Reply: TStationMessage;
  Messages: TStationMessages;
  I: Integer;

function ExpandTemplate(const Template, MyValue, HisValue, ExchangeValue: string): string;
begin
  Result := StringReplace(Template, '<my>', MyValue, [rfReplaceAll]);
  Result := StringReplace(Result, '<his>', HisValue, [rfReplaceAll]);
  Result := StringReplace(Result, '<#>', ExchangeValue, [rfReplaceAll]);
end;

function TemplateFor(const Message: TStationMessage): string;
begin
  case Message of
{TEMPLATE_CASES}
  msgNone: Result := '';
  else raise Exception.Create('Unsupported contest message template: ' + GetEnumName(TypeInfo(TStationMessage), Ord(Message)));
  end;
end;

procedure SendMsg(const Message: TStationMessage);
var
  Text: string;
begin
  if Message = msgHisCall then Tst.SetHisCall(Mainform.Edit1.Text);
  if Message = msgNR then NrSent := True;
  Include(Messages, Message);
  Text := ExpandTemplate(TemplateFor(Message), OwnCall, Mainform.Edit1.Text, OwnExchange);
  if Text <> '' then
  begin
    if UserTx <> '' then UserTx := UserTx + ' ';
    UserTx := UserTx + Text;
  end;
end;

procedure DisplayError(const Text: string; Color: Integer = 0);
begin
  ErrorText := Text;
end;

procedure ProcessEnter;
var
  C, N, R, Q: Boolean;
  ValidCall: Boolean;
  ExchError: string;
begin
{PROCESS_ENTER_BODY}
end;

procedure AppendSet(var Values: TJSONArray; const MessageSet: TStationMessages);
var
  Message: TStationMessage;
begin
  for Message := Low(TStationMessage) to High(TStationMessage) do
    if Message in MessageSet then Values.Add(GetEnumName(TypeInfo(TStationMessage), Ord(Message)));
end;

begin
  while not EOF do
  begin
    ReadLn(Line);
    Request := GetJSON(Line) as TJSONObject;
    try
      CallerCall := Request.Get('caller', 'K1ABC');
      OwnCall := Request.Get('own', 'VE3NEA');
      OwnExchange := Request.Get('ownExchange', '5NN 001');
      CallerExchange := Request.Get('callerExchange', '599 001');
      SimContest := scWpx;
      RunMode := rmSingle;
      Lids := False;
      ActiveCaller := True;
      Tst.Me.HisCall := '';
      CallSent := False;
      NrSent := False;
      Draw := Request.Get('draw', 0.5);
      DrawCount := 0;
      Steps := Request.Arrays['steps'];
      StepOutputs := TJSONArray.Create;
      Op := TDxOperator.Create(CallerCall, osNeedQso);
      try
        Op.State := osNeedQso;
        Op.Patience := Request.Get('patience', 5);
        Op.R2 := Request.Get('style', 0.7);
        Op.Skills := 2;
        Op.SendNrQmCnt := 0;
        for I := 0 to Steps.Count - 1 do
        begin
          StepRequest := Steps.Objects[I];
          Mainform.Edit1.Text := StepRequest.Get('call', '');
          Mainform.Edit2.Text := StepRequest.Get('exchange1', '');
          Mainform.Edit3.Text := StepRequest.Get('exchange2', '');
          ValidCallBoundary := StepRequest.Get('validCall', False);
          MatchResult := StepRequest.Get('match', 0);
          if MatchResult = 100 then MatchResult := 1
          else if MatchResult > 0 then MatchResult := 2;
          UserTx := '';
          ErrorText := '';
          Messages := [];
          ProcessEnter;
          Reply := msgNone;
          RxText := '';
          if Messages <> [] then
          begin
            Op.MsgReceived(Messages);
            Reply := Op.GetReply;
            RxText := ExpandTemplate(TemplateFor(Reply), CallerCall, OwnCall, CallerExchange);
          end;
          StepOutput := TJSONObject.Create;
          StepOutput.Add('call', Mainform.Edit1.Text);
          StepOutput.Add('tx', UserTx);
          MessageList := TJSONArray.Create;
          AppendSet(MessageList, Messages);
          StepOutput.Add('messages', MessageList);
          StepOutput.Add('rxMessage', GetEnumName(TypeInfo(TStationMessage), Ord(Reply)));
          StepOutput.Add('rx', RxText);
          StepOutput.Add('state', GetEnumName(TypeInfo(TOperatorState), Ord(Op.State)));
          StepOutputs.Add(StepOutput);
        end;
        Output := TJSONObject.Create;
        Output.Add('steps', StepOutputs);
        StepOutputs := nil;
        WriteLn(Output.AsJSON);
        Output.Free;
      finally
        Op.Free;
        StepOutputs.Free;
      end;
    finally
      Request.Free;
    end;
  end;
end.
