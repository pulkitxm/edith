import React from 'react';
import {colors} from '../tokens';

export const KeyCap: React.FC<{glyph: string; pressed: number}> = ({
  glyph,
  pressed,
}) => {
  const scale = 1 - pressed * 0.08;
  return (
    <div
      style={{
        width: 76,
        height: 76,
        borderRadius: 16,
        background: pressed > 0.5 ? colors.accent : '#1c1814',
        border: `1px solid ${colors.border}`,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontSize: 28,
        fontWeight: 700,
        color: pressed > 0.5 ? '#1a1208' : colors.text,
        transform: `scale(${scale})`,
        boxShadow:
          pressed > 0.5
            ? '0 0 30px rgba(245,166,35,0.5)'
            : '0 6px 0 rgba(0,0,0,0.4)',
      }}
    >
      {glyph}
    </div>
  );
};
