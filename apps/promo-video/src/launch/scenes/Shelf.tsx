import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {IconTile} from '../components/Icon';
import {Eyebrow, Kinetic} from '../components/Kinetic';
import {extensions} from '../data';
import {display, ink, pop, useLayout} from '../theme';

const picks = ['notchShelf', 'clipboard', 'music', 'virtualCamera', 'machines', 'terminal']
  .map((id) => extensions.find((e) => e.id === id))
  .filter((e): e is (typeof extensions)[number] => Boolean(e));

export const Shelf: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {square} = useLayout();
  const cols = square ? 2 : 3;
  const cardWidth = square ? 470 : 540;
  return (
    <Backdrop glow={ink.violet}>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', gap: square ? 40 : 56}}>
        <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14}}>
          <Eyebrow delay={0}>And everything else</Eyebrow>
          <Kinetic words={['All', 'in', 'one', {text: 'native app.', gold: true}]} delay={3} size={square ? 80 : 88} />
        </div>
        <div style={{display: 'grid', gridTemplateColumns: `repeat(${cols}, ${cardWidth}px)`, gap: square ? 20 : 28}}>
          {picks.map((e, i) => {
            const p = pop(frame, fps, 14 + i * 7, true);
            return (
              <div
                key={e.id}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 22,
                  padding: square ? '22px 24px' : '26px 30px',
                  borderRadius: 26,
                  background: 'linear-gradient(160deg, #23232a, #16161b)',
                  border: '1px solid rgba(233,182,90,0.3)',
                  boxShadow: '0 30px 70px rgba(0,0,0,0.45)',
                  transform: `translateY(${(1 - p) * 40}px)`,
                  opacity: p,
                  fontFamily: display,
                }}
              >
                <IconTile name={e.id} size={square ? 76 : 84} glow={0.4} tint={ink.goldLight} />
                <div style={{minWidth: 0}}>
                  <div style={{fontSize: square ? 34 : 38, fontWeight: 700, letterSpacing: '-0.02em', color: ink.text}}>{e.title}</div>
                  <div style={{fontSize: square ? 22 : 24, color: ink.textSoft, marginTop: 6}}>{e.tagline}</div>
                </div>
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Backdrop>
  );
};
