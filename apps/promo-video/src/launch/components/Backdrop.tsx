import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {ink} from '../theme';

export const Backdrop: React.FC<{glow?: string; intensity?: number; children?: React.ReactNode}> = ({
  glow = ink.gold,
  intensity = 1,
  children,
}) => {
  const frame = useCurrentFrame();
  const drift = Math.sin(frame / 90) * 6;
  return (
    <AbsoluteFill style={{background: ink.night, overflow: 'hidden'}}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(70% 60% at ${50 + drift}% 0%, ${ink.navyLight} 0%, ${ink.navy} 38%, ${ink.navyDeep} 70%, ${ink.night} 100%)`,
        }}
      />
      <AbsoluteFill
        style={{
          background: `radial-gradient(40% 32% at 50% ${18 + drift / 3}%, ${glow}, transparent 70%)`,
          opacity: 0.14 * intensity,
        }}
      />
      <AbsoluteFill
        style={{
          backgroundImage:
            'linear-gradient(rgba(255,255,255,0.025) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.025) 1px, transparent 1px)',
          backgroundSize: '64px 64px',
          backgroundPosition: `0 ${frame * 0.3}px`,
          maskImage: 'radial-gradient(80% 70% at 50% 40%, black, transparent)',
        }}
      />
      {children}
    </AbsoluteFill>
  );
};
