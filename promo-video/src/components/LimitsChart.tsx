import React from 'react';
import {colors} from '../tokens';

// Stand-in 24h samples shaped like real usage: session resets every ~5h
// (sawtooth), weekly climbs steadily. Stepped (stepEnd) like the real chart.
const SESSION: number[] = [8, 22, 38, 55, 4, 18, 30, 46, 6, 20, 14];
const WEEKLY: number[] = [18, 19, 21, 23, 24, 26, 28, 29, 31, 33, 35];

const W = 640;
const H = 130;
const PAD_L = 24;
const PAD_R = 8;

const stepPath = (values: number[]) => {
  const n = values.length - 1;
  const x = (i: number) => PAD_L + ((W - PAD_L - PAD_R) * i) / n;
  const y = (v: number) => H - (H * v) / 100;
  let d = `M ${x(0)} ${y(values[0])}`;
  for (let i = 1; i < values.length; i++) {
    d += ` L ${x(i)} ${y(values[i - 1])} L ${x(i)} ${y(values[i])}`;
  }
  return d;
};

export const LimitsChart: React.FC<{progress: number}> = ({progress}) => {
  const revealWidth = W * Math.max(0, Math.min(1, progress));

  return (
    <svg width="100%" viewBox={`0 0 ${W} ${H}`} style={{overflow: 'visible'}}>
      <defs>
        <clipPath id="reveal">
          <rect x={0} y={0} width={revealWidth} height={H} />
        </clipPath>
      </defs>

      {[0, 50, 100].map((v) => (
        <line
          key={v}
          x1={PAD_L}
          x2={W - PAD_R}
          y1={H - (H * v) / 100}
          y2={H - (H * v) / 100}
          stroke={colors.text}
          strokeOpacity={0.08}
          strokeWidth={1}
        />
      ))}
      {/* warn (60) / critical (85) threshold rules */}
      <line
        x1={PAD_L}
        x2={W - PAD_R}
        y1={H - (H * 60) / 100}
        y2={H - (H * 60) / 100}
        stroke="#e08a2e"
        strokeOpacity={0.4}
        strokeWidth={1}
        strokeDasharray="4 4"
      />
      <line
        x1={PAD_L}
        x2={W - PAD_R}
        y1={H - (H * 85) / 100}
        y2={H - (H * 85) / 100}
        stroke="#d64545"
        strokeOpacity={0.4}
        strokeWidth={1}
        strokeDasharray="4 4"
      />

      <g clipPath="url(#reveal)">
        <path d={stepPath(WEEKLY)} fill="none" stroke={colors.textDim} strokeWidth={1.5} />
        <path d={stepPath(SESSION)} fill="none" stroke={colors.accent} strokeWidth={1.5} />
      </g>

      {[0, 50, 100].map((v) => (
        <text
          key={v}
          x={0}
          y={H - (H * v) / 100 + 4}
          fill={colors.label}
          fontSize={11}
        >
          {v}
        </text>
      ))}
    </svg>
  );
};
