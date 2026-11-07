import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {Icon} from '../components/Icon';
import {beat, display, goldGradient, ink, pop, useLayout} from '../theme';

const words = ['Local.', 'Private.', 'Open source.'];
const chips = ['No account', 'No telemetry', 'No paid tier', 'GPL-3.0'];

export const Privacy: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {square, width} = useLayout();
  return (
    <Backdrop glow={ink.green} intensity={0.8}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', gap: square ? 40 : 52}}>
        <div style={{transform: `scale(${pop(frame, fps, 0, true)})`}}>
          <Icon name="shield" size={square ? 100 : 110} color={ink.gold} />
        </div>
        <div style={{display: 'flex', flexDirection: square ? 'column' : 'row', alignItems: 'center', gap: square ? 0 : 40}}>
          {words.map((w, i) => {
            const p = pop(frame, fps, 4 + i * (beat / 2), true);
            return (
              <div
                key={w}
                style={{
                  fontFamily: display,
                  fontSize: square ? 136 : 128,
                  lineHeight: 1.05,
                  fontWeight: 800,
                  letterSpacing: '-0.05em',
                  opacity: p,
                  transform: `translateY(${(1 - p) * 50}px) scale(${0.9 + p * 0.1})`,
                  backgroundImage: i === 2 ? goldGradient : undefined,
                  WebkitBackgroundClip: i === 2 ? 'text' : undefined,
                  WebkitTextFillColor: i === 2 ? 'transparent' : undefined,
                  color: ink.text,
                  paddingBottom: '0.06em',
                }}
              >
                {w}
              </div>
            );
          })}
        </div>
        <div style={{display: 'flex', flexWrap: 'wrap', justifyContent: 'center', gap: 16, maxWidth: width - 100}}>
          {chips.map((c, i) => {
            const p = pop(frame, fps, beat * 2 + i * 3, true);
            return (
              <div
                key={c}
                style={{
                  padding: '14px 28px',
                  borderRadius: 999,
                  border: '1px solid rgba(255,255,255,0.16)',
                  background: 'rgba(255,255,255,0.05)',
                  color: ink.text,
                  fontFamily: display,
                  fontSize: 30,
                  fontWeight: 600,
                  transform: `scale(${p})`,
                  opacity: p,
                }}
              >
                {c}
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Backdrop>
  );
};
