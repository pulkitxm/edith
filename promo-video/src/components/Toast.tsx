import React from 'react';
import {colors, fontFamily} from '../tokens';

export const Toast: React.FC<{x: number; opacity: number}> = ({x, opacity}) => {
  return (
    <div
      style={{
        position: 'absolute',
        top: 60,
        right: 0,
        transform: `translateX(${x}px)`,
        opacity,
        width: 360,
        borderRadius: 16,
        background: '#171310',
        border: `1px solid ${colors.border}`,
        boxShadow: '0 20px 60px rgba(0,0,0,0.5)',
        padding: '18px 20px',
        display: 'flex',
        gap: 14,
        fontFamily,
      }}
    >
      <div
        style={{
          width: 36,
          height: 36,
          borderRadius: 10,
          background: colors.accentSoft,
          color: colors.accent,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 18,
          flexShrink: 0,
        }}
      >
        &#9889;
      </div>
      <div>
        <div style={{color: colors.text, fontSize: 16, fontWeight: 700}}>
          Weekly: burning hot
        </div>
        <div style={{color: colors.textDim, fontSize: 14, marginTop: 4}}>
          Way ahead of pace, pump the brakes
        </div>
      </div>
    </div>
  );
};
