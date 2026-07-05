import React from 'react';
import {colors} from '../tokens';
import {interpolate} from 'remotion';

const ROWS = 7; 
const DAY_LABELS = ['M', '', 'W', '', 'F', '', 'S'];
const COLS = 18; 
const MONTH_LABELS = [
  'Feb', '', '', '',
  'Mar', '', '', '',
  'Apr', '', '', '',
  'May', '', '', '',
  'Jun', '',
];

const levelAt = (i: number) => {
  const seed = Math.sin(i * 12.9898) * 43758.5453;
  const r = seed - Math.floor(seed);
  if (r < 0.08) return 0;
  if (r < 0.35) return 1;
  if (r < 0.65) return 2;
  if (r < 0.88) return 3;
  return 4;
};

const cellColor = (level: number) => {
  if (level === 0) return 'rgba(255,255,255,0.08)';
  const opacity = [0, 0.25, 0.45, 0.7, 1][level];
  return `rgba(245, 166, 35, ${opacity})`;
};

export const HeatmapGrid: React.FC<{progress: number; cellSize?: number}> = ({
  progress,
  cellSize = 32,
}) => {
  const gap = 8;

  return (
    <div style={{display: 'flex', gap: 10}}>
      <div style={{display: 'flex', flexDirection: 'column', gap, paddingTop: cellSize + gap}}>
        {DAY_LABELS.map((label, i) => (
          <div
            key={i}
            style={{
              width: 16,
              height: cellSize,
              display: 'flex',
              alignItems: 'center',
              color: colors.label,
              fontSize: 12,
            }}
          >
            {label}
          </div>
        ))}
      </div>
      <div>
        <div style={{display: 'flex', gap, marginBottom: gap, height: cellSize}}>
          {MONTH_LABELS.map((label, i) => (
            <div key={i} style={{width: cellSize, color: colors.label, fontSize: 12}}>
              {label}
            </div>
          ))}
        </div>
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: `repeat(${COLS}, ${cellSize}px)`,
            gridTemplateRows: `repeat(${ROWS}, ${cellSize}px)`,
            gridAutoFlow: 'column',
            gap,
          }}
        >
          {Array.from({length: ROWS * COLS}).map((_, i) => {
            const col = Math.floor(i / ROWS);
            const delay = (col / (COLS - 1)) * 0.8 + (i % ROWS) * 0.02;
            const p = Math.max(0, Math.min(1, (progress - delay) / 0.25));
            const scale = interpolate(p, [0, 1], [0.3, 1]);
            const opacity = interpolate(p, [0, 1], [0, 1]);
            return (
              <div
                key={i}
                style={{
                  width: cellSize,
                  height: cellSize,
                  borderRadius: 7,
                  background: cellColor(levelAt(i)),
                  opacity,
                  transform: `scale(${scale})`,
                }}
              />
            );
          })}
        </div>
      </div>
    </div>
  );
};
