import React from 'react';
import {colors} from '../tokens';

export const TrackRow: React.FC<{
  title: string;
  duration: string;
  hue: number;
  current?: boolean;
  playing?: boolean;
  opacity?: number;
}> = ({title, duration, hue, current, playing, opacity = 1}) => {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 14,
        padding: '10px 12px',
        borderRadius: 10,
        background: current ? 'rgba(255,255,255,0.08)' : 'transparent',
        opacity,
      }}
    >
      <div
        style={{
          width: 40,
          height: 40,
          borderRadius: 9,
          background: `linear-gradient(180deg, hsl(${hue}, 55%, 45%), hsl(${hue}, 60%, 22%))`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 15,
          color: 'rgba(255,255,255,0.8)',
          flexShrink: 0,
        }}
      >
        &#9835;
      </div>
      <span style={{color: current ? colors.accent : colors.text, fontSize: 16, flex: 1}}>
        {title}
      </span>
      {current && (
        <span style={{color: colors.accent, fontSize: 14}}>
          {playing ? '\u{1F50A}' : '\u{23F8}'}
        </span>
      )}
      <span style={{color: colors.label, fontSize: 13}}>{duration}</span>
    </div>
  );
};
