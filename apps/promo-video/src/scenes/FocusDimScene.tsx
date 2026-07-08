import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {Caption} from '../components/Caption';
import {ToggleSwitch} from '../components/ToggleSwitch';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

const Window: React.FC<{x: number; y: number; dim: number; front?: boolean}> = ({
  x,
  y,
  dim,
  front,
}) => (
  <div
    style={{
      position: 'absolute',
      left: x,
      top: y,
      width: 420,
      height: 280,
      borderRadius: 16,
      background: 'linear-gradient(135deg, #23201b 0%, #14110d 100%)',
      border: `1px solid ${colors.border}`,
      boxShadow: front
        ? '0 40px 100px rgba(0,0,0,0.6)'
        : '0 20px 60px rgba(0,0,0,0.4)',
      overflow: 'hidden',
    }}
  >
    <div style={{display: 'flex', gap: 8, padding: 16}}>
      {['#ff5f57', '#febc2e', '#28c840'].map((c) => (
        <div key={c} style={{width: 12, height: 12, borderRadius: 6, background: c}} />
      ))}
    </div>
    <div
      style={{
        position: 'absolute',
        inset: 0,
        background: '#050403',
        opacity: dim,
      }}
    />
  </div>
);

export const FocusDimScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const toggle = interpolate(springIn(frame, fps, 24), [0, 1], [0, 1]);
  const dim = toggle * 0.62;

  return (
    <Background>
      <div style={{position: 'relative', width: 720, height: 460}}>
        <Window x={0} y={40} dim={dim} />
        <Window x={220} y={150} dim={0} front />

        <div
          style={{
            position: 'absolute',
            right: -40,
            top: 0,
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            fontFamily,
            color: colors.textDim,
            fontSize: 16,
            fontWeight: 600,
          }}
        >
          <span>Focus Dim</span>
          <ToggleSwitch progress={toggle} />
        </div>
      </div>

      <Caption>Focus Dim - everything but the front window fades back</Caption>
    </Background>
  );
};
