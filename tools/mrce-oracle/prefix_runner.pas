//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
// Test-only driver for the pinned CallsignUtils.ExtractPrefix. Reads one call
// per line and prints "<call> <WPX prefix>". The function body is pasted in
// unmodified by generate_prefix.py; no prefix decisions live here.
program prefix_runner;
{$mode delphi}{$H+}
uses SysUtils;
{EXTRACT_PREFIX}
var
  Line: string;
begin
  while not Eof(Input) do
  begin
    ReadLn(Line);
    Line := Trim(Line);
    if Line = '' then Continue;
    WriteLn(Line, ' ', ExtractPrefix(Line, True));
  end;
end.
