import React from 'react';
import {interpolate} from 'remotion';
import {colors} from '../tokens';
import {springIn} from '../animation';

export const StatRow: React.FC<{
  label: string;
  value: number;
  suffix?: string;
  cost: number;
  frame: number;
  fps: number;
  delay: number;
}> = ({label, value, suffix = '', cost, frame, fps, delay}) => {
  const p = springIn(frame, fps, delay);
  const shown = interpolate(p, [0, 1], [0, value]);
  // matches Double.compactTokens in UsageView.swift: B keeps 2 decimals, M/K keep 1
  const decimals = suffix === 'B' ? 2 : suffix ? 1 : 0;

  return (
    <div
      style={{
        display: 'flex',
        justifyContent: 'space-between',
        alignItems: 'baseline',
        padding: '14px 0',
        opacity: interpolate(p, [0, 1], [0, 1]),
      }}
    >
      <span style={{color: colors.textDim, fontSize: 18}}>{label}</span>
      <span style={{display: 'flex', gap: 28}}>
        <span style={{color: colors.text, fontSize: 22}}>
          {shown.toFixed(decimals)}
          {suffix}
        </span>
        <span style={{color: colors.textDim, fontSize: 22}}>
          ${(cost * (shown / value || 0)).toFixed(2)}
        </span>
      </span>
    </div>
  );
};
