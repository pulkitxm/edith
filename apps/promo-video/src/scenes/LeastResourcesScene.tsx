import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {Caption} from '../components/Caption';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

const Stat: React.FC<{value: string; label: string; delay: number}> = ({
  value,
  label,
  delay,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const p = springIn(frame, fps, delay, true);
  return (
    <div
      style={{
        opacity: interpolate(p, [0, 1], [0, 1]),
        transform: `translateY(${interpolate(p, [0, 1], [22, 0])}px)`,
        textAlign: 'center',
      }}
    >
      <div style={{color: colors.accent, fontSize: 88, fontWeight: 800, lineHeight: 1}}>
        {value}
      </div>
      <div style={{color: colors.label, fontSize: 16, letterSpacing: 2, marginTop: 12}}>
        {label}
      </div>
    </div>
  );
};

export const LeastResourcesScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const head = springIn(frame, fps, 0);

  return (
    <Background>
      <div
        style={{
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          fontFamily,
        }}
      >
        <div
          style={{
            color: colors.textDim,
            fontSize: 24,
            fontWeight: 600,
            marginBottom: 60,
            opacity: interpolate(head, [0, 1], [0, 1]),
            transform: `translateY(${interpolate(head, [0, 1], [14, 0])}px)`,
          }}
        >
          All of it, idling on nothing.
        </div>

        <div style={{display: 'flex', gap: 130}}>
          <Stat value="~0%" label="CPU, PANEL CLOSED" delay={12} />
          <Stat value="22 MB" label="MEMORY" delay={22} />
        </div>
      </div>

      <Caption>Work stops when it isn't seen - built to run 24/7</Caption>
    </Background>
  );
};
