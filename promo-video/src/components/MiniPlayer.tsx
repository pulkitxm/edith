import React from 'react';
import {colors, fontFamily} from '../tokens';

const timeLabel = (t: number) => {
  const s = Math.max(0, Math.round(t));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};

// Matches MusicView.swift's nowPlayingBar: scrubber+time row, then
// thumb/title/visualizer/transport/volume in one row - no big centered player.
export const MiniPlayer: React.FC<{
  title: string;
  progress: number; // 0-1 scrubber position
  duration: number; // seconds
  playing: boolean;
  bars: number[]; // 0-1 heights
}> = ({title, progress, duration, playing, bars}) => {
  return (
    <div style={{display: 'flex', flexDirection: 'column', gap: 10, fontFamily}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 10}}>
        <span style={{color: colors.textDim, fontSize: 13, width: 40}}>
          {timeLabel(progress * duration)}
        </span>
        <div style={{flex: 1, height: 4, borderRadius: 2, background: colors.track, position: 'relative'}}>
          <div
            style={{
              position: 'absolute',
              left: 0,
              top: 0,
              height: 4,
              width: `${progress * 100}%`,
              borderRadius: 2,
              background: colors.accent,
            }}
          />
        </div>
        <span style={{color: colors.textDim, fontSize: 13, width: 40, textAlign: 'right'}}>
          {timeLabel(duration)}
        </span>
      </div>

      <div style={{display: 'flex', alignItems: 'center', gap: 14}}>
        <div
          style={{
            width: 44,
            height: 44,
            borderRadius: 10,
            background: 'linear-gradient(180deg, hsl(20, 55%, 45%), hsl(20, 60%, 22%))',
            flexShrink: 0,
          }}
        />
        <span style={{color: colors.text, fontSize: 17, fontWeight: 600}}>{title}</span>

        <div style={{display: 'flex', gap: 4, alignItems: 'flex-end', height: 22}}>
          {bars.map((h, i) => (
            <div
              key={i}
              style={{
                width: 4,
                height: Math.max(3, h * 22),
                borderRadius: 2,
                background: colors.accent,
                opacity: 0.6 + h * 0.4,
              }}
            />
          ))}
        </div>

        <div style={{flex: 1}} />

        <span style={{color: colors.accent, fontSize: 17}}>&#9198;</span>
        <span style={{color: colors.accent, fontSize: 22}}>{playing ? '⏸' : '▶'}</span>
        <span style={{color: colors.accent, fontSize: 17}}>&#9197;</span>

        <div style={{width: 70, height: 4, borderRadius: 2, background: colors.track, marginLeft: 8}}>
          <div style={{width: '65%', height: 4, borderRadius: 2, background: colors.accent}} />
        </div>
      </div>
    </div>
  );
};
