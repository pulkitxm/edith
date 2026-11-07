import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {Eyebrow, Kinetic} from '../components/Kinetic';
import {NotchMark} from '../components/NotchMark';
import {beat, display, goldGradient, ink, pop, ramp, sharp, useLayout} from '../theme';

export const introDuration = beat * 9;

export const Intro: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {square} = useLayout();
  const build = ramp(frame, 0, 34);
  const shine = ramp(frame, 34, 56);
  const badge = pop(frame, fps, beat * 3, true);
  const exit = ramp(frame, introDuration - 8, introDuration, [0, 1], sharp);
  const markSize = square ? 300 : 280;
  return (
    <Backdrop intensity={1 + build}>
      <AbsoluteFill
        style={{
          alignItems: 'center',
          justifyContent: 'center',
          gap: 18,
          transform: `scale(${1 + exit * 0.12})`,
          opacity: 1 - exit,
        }}
      >
        <div style={{position: 'relative', filter: `drop-shadow(0 30px 60px ${ink.shadow})`}}>
          <div
            style={{
              position: 'absolute',
              inset: -markSize * 0.6,
              borderRadius: '50%',
              background: 'radial-gradient(circle, rgba(233,182,90,0.35), transparent 62%)',
              opacity: build,
            }}
          />
          <NotchMark size={markSize} progress={build} shine={shine} />
        </div>
        <Eyebrow delay={22}>Introducing</Eyebrow>
        <div style={{display: 'flex', alignItems: 'center', gap: 28}}>
          <Kinetic words={['Edith']} delay={28} size={square ? 190 : 200} />
          <div
            style={{
              fontFamily: display,
              fontSize: square ? 92 : 100,
              fontWeight: 800,
              letterSpacing: '-0.04em',
              padding: '4px 30px 10px',
              borderRadius: 26,
              color: ink.night,
              background: goldGradient,
              boxShadow: `0 0 ${60 * badge}px rgba(233,182,90,0.6)`,
              transform: `scale(${badge}) rotate(${(1 - badge) * -12}deg)`,
              opacity: badge,
            }}
          >
            V1
          </div>
        </div>
        <div
          style={{
            fontFamily: display,
            fontSize: square ? 40 : 42,
            fontWeight: 500,
            color: ink.textSoft,
            opacity: ramp(frame, beat * 3 + 6, beat * 3 + 16),
            transform: `translateY(${ramp(frame, beat * 3 + 6, beat * 3 + 16, [12, 0])}px)`,
            textAlign: 'center',
          }}
        >
          Every tool your Mac is missing. One app.
        </div>
      </AbsoluteFill>
    </Backdrop>
  );
};
