import React from 'react';
import {useCurrentFrame, useVideoConfig} from 'remotion';
import {colors} from '../tokens';

const formatCountdown = (totalSeconds: number) => {
  const s = Math.max(0, Math.round(totalSeconds));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (d > 0) return `${d}d ${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
  return `${m}:${String(sec).padStart(2, '0')}`;
};

export const Ring: React.FC<{
  percent: number;
  progress: number; 
  size?: number;
  label: string;
  startSeconds: number;
}> = ({percent, progress, size = 220, label, startSeconds}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const sublabel = formatCountdown(startSeconds - frame / fps);
  const stroke = 14;
  const r = (size - stroke) / 2;
  const circumference = 2 * Math.PI * r;
  const shown = percent * progress;
  const offset = circumference * (1 - shown / 100);

  return (
    <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center'}}>
      <div style={{position: 'relative', width: size, height: size}}>
        <svg width={size} height={size} style={{transform: 'rotate(-90deg)'}}>
          <circle
            cx={size / 2}
            cy={size / 2}
            r={r}
            stroke={colors.track}
            strokeWidth={stroke}
            fill="none"
          />
          <circle
            cx={size / 2}
            cy={size / 2}
            r={r}
            stroke={colors.accent}
            strokeWidth={stroke}
            fill="none"
            strokeLinecap="round"
            strokeDasharray={circumference}
            strokeDashoffset={offset}
          />
        </svg>
        <div
          style={{
            position: 'absolute',
            inset: 0,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            color: colors.text,
            fontSize: size * 0.2,
            fontWeight: 700,
          }}
        >
          {Math.round(shown)}%
        </div>
      </div>
      <div
        style={{
          marginTop: 18,
          color: colors.label,
          fontSize: 13,
          letterSpacing: 2,
          fontWeight: 600,
        }}
      >
        {label}
      </div>
      <div style={{marginTop: 6, color: colors.textDim, fontSize: 15}}>
        {sublabel}
      </div>
    </div>
  );
};
