import React from 'react';
import {interpolateColors} from 'remotion';
import {colors} from '../tokens';

export const ToggleSwitch: React.FC<{progress: number; size?: number}> = ({
  progress,
  size = 64,
}) => {
  const height = size * 0.56;
  const knob = height - 8;
  const track = interpolateColors(progress, [0, 1], [colors.track, colors.accent]);
  const knobX = 4 + progress * (size - knob - 8);

  return (
    <div
      style={{
        width: size,
        height,
        borderRadius: height / 2,
        background: track,
        position: 'relative',
      }}
    >
      <div
        style={{
          position: 'absolute',
          top: 4,
          left: knobX,
          width: knob,
          height: knob,
          borderRadius: knob / 2,
          background: '#fff',
          boxShadow: '0 2px 6px rgba(0,0,0,0.3)',
        }}
      />
    </div>
  );
};
