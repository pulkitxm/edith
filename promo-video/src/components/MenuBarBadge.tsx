import React from 'react';
import {colors, fontFamily} from '../tokens';

// Matches LimitsStatusItem.swift's real format: "5h 14%  7d 35%",
// each number tinted by risk (theme color here, kept consistent with the rest).
export const MenuBarBadge: React.FC<{reveal: number}> = ({reveal}) => {
  return (
    <div
      style={{
        width: 640,
        height: 36,
        borderRadius: 8,
        background: '#141210',
        border: `1px solid ${colors.border}`,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'flex-end',
        gap: 18,
        padding: '0 16px',
        fontFamily,
      }}
    >
      <div
        style={{
          display: 'flex',
          gap: 6,
          alignItems: 'baseline',
          opacity: reveal,
          transform: `scale(${0.7 + reveal * 0.3})`,
        }}
      >
        <span style={{color: colors.textDim, fontSize: 11, fontWeight: 700}}>5h</span>
        <span style={{color: colors.accent, fontSize: 15, fontWeight: 600}}>14%</span>
        <span style={{color: colors.textDim, fontSize: 11, fontWeight: 700, marginLeft: 8}}>
          7d
        </span>
        <span style={{color: colors.accent, fontSize: 15, fontWeight: 600}}>35%</span>
      </div>
      <span style={{color: colors.textDim, fontSize: 13}}>Tue 11:47 PM</span>
    </div>
  );
};
