import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {Eyebrow, Kinetic} from '../components/Kinetic';
import {NotchMark} from '../components/NotchMark';
import {display, ink, ramp, smooth} from '../theme';

export const Reveal: React.FC = () => {
  const frame = useCurrentFrame();
  const build = ramp(frame, 0, 84, [0, 1], smooth);
  const settle = ramp(frame, 96, 124, [0, 1], smooth);
  const shine = ramp(frame, 84, 112, [0, 1]);
  const size = interpolate(settle, [0, 1], [560, 300]);
  const y = interpolate(settle, [0, 1], [0, -150]);
  const halo = 0.5 + 0.5 * Math.sin(frame / 14);
  return (
    <Backdrop intensity={1 + build}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div
          style={{
            position: 'absolute',
            width: 900,
            height: 900,
            borderRadius: 450,
            background: 'radial-gradient(circle, rgba(233,182,90,0.22), transparent 60%)',
            opacity: build * (0.7 + halo * 0.3),
            transform: `translateY(${y}px)`,
          }}
        />
        <div style={{transform: `translateY(${y}px)`, filter: 'drop-shadow(0 30px 60px rgba(0,0,0,0.6))'}}>
          <NotchMark size={size} progress={build} shine={shine} />
        </div>
      </AbsoluteFill>
      {frame >= 104 ? (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', top: 300, gap: 26}}>
          <Eyebrow delay={106}>Introducing the new</Eyebrow>
          <Kinetic words={[{text: 'Edith', gold: true}]} delay={110} size={170} />
          <div
            style={{
              fontFamily: display,
              fontSize: 36,
              color: ink.textSoft,
              opacity: ramp(frame, 136, 156),
              letterSpacing: '-0.01em',
            }}
          >
            New logo. New design. A whole new way to build your Mac.
          </div>
        </AbsoluteFill>
      ) : null}
    </Backdrop>
  );
};
