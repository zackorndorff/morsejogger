//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
{ Test-only dependencies. No dialogue or reply decisions live here. }
unit OracleSupport;
{$mode delphi}{$H+}
interface
type
{STATION_MESSAGES}
  TStationSpeedState = (ssNormalSpeed, ssSlowingDown);
  TRunMode = (rmPileup, rmSingle, rmHst);
  TSimContest = (scWpx, scArrlSS, scNaQp);
  TEdit = class
    Text: string;
  end;
  TMain = class
    Edit1, Edit2, Edit3: TEdit;
  end;
const
  clDefault = 0;
type
  TTestMe = class
    HisCall: string;
  end;
  TContest = class
    Me: TTestMe;
    function IsFarnsworthAllowed: Boolean;
    procedure OnExchangeEditComplete;
    procedure SetHisCall(const ACall: string);
    function ValidateEnteredCall(const ACall: string; out AError: string): Boolean;
    function ValidateEnteredExchange(const ACall, AExch1, AExch2: string; out AError: string): Boolean;
  end;
  TNcjNaQp = class(TContest)
    function IsCallLocalToContest(const ACall: string): Boolean;
  end;
  TOracleLog = class
    procedure ClearError;
    procedure SaveQso;
  end;
var
  RunMode: TRunMode;
  SimContest: TSimContest;
  Lids, Stay, ActiveCaller: Boolean;
  MatchResult: Integer;
  CallSent, NrSent, ValidCallBoundary, MustAdvance: Boolean;
  Log: TOracleLog;
  Tst: TContest;
  Mainform: TMain;
  Draw: Double;
  DrawCount: Integer;
function Random: Double; overload;
function Random(Limit: Integer): Integer; overload;
function RndRayleigh(AMean: Single): Single;
function AllowCallerToStay: Boolean;
function AllowCallerToQrs: Boolean;
implementation
uses Math, SysUtils;
function Random: Double;
begin Inc(DrawCount); Result := Draw; end;
function Random(Limit: Integer): Integer;
begin Result := Trunc(Random * Limit); end;
{RAYLEIGH_IMPLEMENTATION}
function AllowCallerToStay: Boolean;
begin Result := Stay or (RunMode = rmHst); end;
function AllowCallerToQrs: Boolean;
begin Result := False; end;
function TContest.IsFarnsworthAllowed: Boolean;
begin Result := False; end;
{CONTEST_METHODS}
function TContest.ValidateEnteredCall(const ACall: string; out AError: string): Boolean;
begin AError := ''; Result := ValidCallBoundary; end;
function TContest.ValidateEnteredExchange(const ACall, AExch1, AExch2: string; out AError: string): Boolean;
begin
  Result := False;
  raise Exception.Create('Contest exchange validation is outside the conversation fixture scope');
end;
function TNcjNaQp.IsCallLocalToContest(const ACall: string): Boolean;
begin
  Result := False;
  raise Exception.Create('NAQP call-locality is outside the conversation fixture scope');
end;
procedure TOracleLog.ClearError;
begin end;
procedure TOracleLog.SaveQso;
begin raise Exception.Create('QSO persistence is outside the conversation fixture scope'); end;
initialization
  Tst := TContest.Create;
  Tst.Me := TTestMe.Create;
  Mainform := TMain.Create;
  Mainform.Edit1 := TEdit.Create;
  Mainform.Edit2 := TEdit.Create;
  Mainform.Edit3 := TEdit.Create;
  Log := TOracleLog.Create;
finalization
  Log.Free;
  Mainform.Edit3.Free;
  Mainform.Edit2.Free;
  Mainform.Edit1.Free;
  Mainform.Free;
  Tst.Me.Free;
  Tst.Free;
end.
