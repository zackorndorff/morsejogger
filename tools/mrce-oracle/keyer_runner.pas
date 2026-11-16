//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
// Test-only driver for the pinned MRCE keyers. Reads one JSON case per line
// with keys keyer ("std" or "farns"), text, wpmS and wpmC, and prints the
// envelope length and each keyed element as [start,length] in samples at
// 11,025 Hz. No timing decisions live here.
program keyer_runner;
{$mode delphi}{$H+}
uses SysUtils, Classes, fpjson, jsonparser, SndTypes, MorseKey, FarnsKeyer;
var
  Line, Marks: string;
  Data: TJSONData;
  Obj: TJSONObject;
  K: TKeyer;
  Env: TSingleArray;
  i, Start, Count: integer;
begin
  while not Eof(Input) do
  begin
    ReadLn(Line);
    if Trim(Line) = '' then Continue;
    Data := GetJSON(Line);
    Obj := Data as TJSONObject;
    if Obj.Get('keyer', 'std') = 'farns'
      then K := TFarnsKeyer.Create(11025, 512)
      else K := TKeyer.Create(11025, 512);
    K.SetWpm(Obj.Get('wpmS', 25), Obj.Get('wpmC', 25));
    K.MorseMsg := K.Encode(Obj.Get('text', ''));
    Env := K.Envelope;
    Marks := '';
    Count := 0;
    Start := -1;
    for i := 0 to High(Env) + 1 do
      if (i <= High(Env)) and (Env[i] <> 0) then
        begin
          if Start < 0 then Start := i;
        end
      else if Start >= 0 then
        begin
          if Count > 0 then Marks := Marks + ',';
          Marks := Marks + Format('[%d,%d]', [Start, i - Start]);
          Inc(Count);
          Start := -1;
        end;
    WriteLn(Format('{"len":%d,"padded":%d,"encoded":"%s","marks":[%s]}',
      [K.TrueEnvelopeLen, Length(Env), StringReplace(K.MorseMsg, '\', '\\', [rfReplaceAll]), Marks]));
    K.Free;
    Data.Free;
  end;
end.
