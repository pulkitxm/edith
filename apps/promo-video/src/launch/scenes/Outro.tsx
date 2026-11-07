import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {Kinetic} from '../components/Kinetic';
import {NotchMark} from '../components/NotchMark';
import {display, ink, mono, pop, ramp, useLayout} from '../theme';

export const Outro: React.FC<{duration: number}> = ({duration}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {square} = useLayout();
  const mark = ramp(frame, 0, 26);
  const shine = ramp(frame, 26, 50);
  const fadeOut = ramp(frame, duration - 14, duration, [1, 0]);
  return (
    <Backdrop intensity={1.6}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', gap: 22, opacity: fadeOut}}>
        <div style={{filter: 'drop-shadow(0 30px 60px rgba(0,0,0,0.6))', marginBottom: 6}}>
          <NotchMark size={240} progress={mark} shine={shine} />
        </div>
        <Kinetic words={['Get', {text: 'Edith V1', gold: true}]} delay={10} size={square ? 120 : 140} />
        <Kinetic words={['Free.', 'Open', 'source.', 'Yours', 'in', 'one', 'command.']} delay={16} size={square ? 46 : 52} stagger={2} weight={600} color={ink.textSoft} maxWidth={square ? 960 : undefined} />
        <div
          style={{
            marginTop: 34,
            display: 'flex',
            flexDirection: square ? 'column' : 'row',
            alignItems: 'center',
            gap: square ? 18 : 26,
            opacity: pop(frame, fps, 26),
            transform: `translateY(${(1 - pop(frame, fps, 26)) * 20}px)`,
          }}
        >
          <div
            style={{
              fontFamily: mono,
              fontSize: 28,
              color: ink.text,
              padding: '16px 28px',
              borderRadius: 14,
              background: 'rgba(255,255,255,0.06)',
              border: '1px solid rgba(255,255,255,0.12)',
            }}
          >
            <span style={{color: ink.gold}}>$</span> brew install --cask pulkitxm/tap/edith
          </div>
          <div style={{fontFamily: display, fontSize: 36, fontWeight: 700, color: ink.goldLight}}>edith.pulkit.page</div>
        </div>
        <div style={{fontFamily: display, fontSize: 24, color: ink.textFaint, opacity: pop(frame, fps, 34)}}>
          macOS 14+ on Apple silicon
        </div>
      </AbsoluteFill>
    </Backdrop>
  );
};
