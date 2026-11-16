//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
// Runs MRCE's receiver tail (Filt/Filt2, Modul, Agc) exactly as TContest.Create
// configures it and TContest.GetAudio calls it, over a deterministic complex
// input. One input line "bandwidth pitch" gives one output line: the RMS of
// each 1024-sample window of the audio MRCE would hand to the sound card.
program receiver_runner;
{$mode delphi}
{$Q-}{$R-}

uses
  SysUtils, Math, SndTypes, MovAvg, Mixers, VolumCtl;

const
  RATE = 11025;
  BUF = 512;
  BLOCKS = 120;
  WINDOW = 2;   // blocks per reported RMS window
  NOISEAMP = 6000;

type
  TTone = record Offset, Amplitude: Double; FirstBlock, LastBlock: integer; end;

const
  // offset Hz, amplitude, first and last block (inclusive)
  TONES: array[0..5] of TTone = (
    (Offset:    0; Amplitude:  27000; FirstBlock:  12; LastBlock:  23),
    (Offset:  200; Amplitude:  45000; FirstBlock:  30; LastBlock:  41),
    (Offset: -350; Amplitude:   9000; FirstBlock:  48; LastBlock:  59),
    (Offset:  120; Amplitude:  18000; FirstBlock:  66; LastBlock:  77),
    (Offset:  -60; Amplitude:  27000; FirstBlock:  72; LastBlock:  83),
    (Offset:    0; Amplitude: 424264; FirstBlock:  96; LastBlock: 107));

var
  Seed: LongWord;

function Uniform: Double;
begin
  Seed := Seed * 1664525 + 1013904223;
  Result := (Seed shr 8) / 16777216.0;
end;

procedure RunCase(Bandwidth, Pitch: integer);
var
  Filt, Filt2, F: TMovingAverage;
  Modul: TModulator;
  Agc: TVolumeControl;
  ReIm: TReImArrays;
  Audio: TSingleArray;
  Block, i, t: integer;
  n: Int64;
  Phase, Sum, V: Double;
  First: boolean;
begin
  Filt := TMovingAverage.Create(nil);
  Modul := TModulator.Create;
  Agc := TVolumeControl.Create(nil);

  Filt.Points := Round(0.7 * RATE / Bandwidth);
  Filt.Passes := 3;
  Filt.SamplesInInput := BUF;
  Filt.GainDb := 10 * Log10(500 / Bandwidth);

  Filt2 := TMovingAverage.Create(nil);
  Filt2.Passes := Filt.Passes;
  Filt2.SamplesInInput := Filt.SamplesInInput;
  Filt2.Points := Filt.Points;
  Filt2.GainDb := Filt.GainDb;

  Modul.SamplesPerSec := RATE;
  Modul.CarrierFreq := Pitch;

  Agc.NoiseInDb := 76;
  Agc.NoiseOutDb := 76;
  Agc.AttackSamples := 155;
  Agc.HoldSamples := 155;
  Agc.AgcEnabled := true;

  Seed := 20261113;
  n := 0;
  Sum := 0;
  First := true;
  Write('{"bandwidth":', Bandwidth, ',"pitch":', Pitch, ',"rms":[');
  for Block := 1 to BLOCKS do
    begin
    SetLengthReIm(ReIm, BUF);
    for i := 0 to BUF - 1 do
      begin
      ReIm.Re[i] := 3 * NOISEAMP * (Uniform - 0.5);
      ReIm.Im[i] := 3 * NOISEAMP * (Uniform - 0.5);
      for t := Low(TONES) to High(TONES) do
        if (Block >= TONES[t].FirstBlock) and (Block <= TONES[t].LastBlock) then
          begin
          // Same form as GetAudio: Re += A*Cos(Bfo), Im -= A*Sin(Bfo)
          Phase := 2 * Pi * TONES[t].Offset * n / RATE;
          ReIm.Re[i] := ReIm.Re[i] + TONES[t].Amplitude * Cos(Phase);
          ReIm.Im[i] := ReIm.Im[i] - TONES[t].Amplitude * Sin(Phase);
          end;
      Inc(n);
      end;

    Filt2.Filter(ReIm);
    ReIm := Filt.Filter(ReIm);
    if (Block mod 10) = 0 then
      begin
      F := Filt; Filt := Filt2; Filt2 := F; Filt2.Reset;
      end;
    Audio := Modul.Modulate(ReIm);
    Audio := Agc.Process(Audio);

    for i := 0 to BUF - 1 do
      begin
      V := Audio[i];
      Sum := Sum + V * V;
      end;
    if (Block mod WINDOW) = 0 then
      begin
      if not First then Write(',');
      First := false;
      Write(FloatToStrF(Sqrt(Sum / (WINDOW * BUF)), ffFixed, 12, 2));
      Sum := 0;
      end;
    end;
  WriteLn(']}');
end;

var
  Bandwidth, Pitch: integer;
begin
  FormatSettings.DecimalSeparator := '.';
  while not Eof do
    begin
    ReadLn(Bandwidth, Pitch);
    if Bandwidth > 0 then RunCase(Bandwidth, Pitch);
    end;
end.
