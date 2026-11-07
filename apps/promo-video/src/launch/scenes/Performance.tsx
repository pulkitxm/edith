import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {Eyebrow, Kinetic} from '../components/Kinetic';
import {facts} from '../data';
import {beat, display, goldGradient, ink, pop, ramp, useLayout} from '../theme';

export const Performance: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {square} = useLayout();
  const memory = Math.round(ramp(frame, beat + 4, beat + 22, [180, facts.idleMemoryMb]));
  const download = ramp(frame, beat * 2 + 4, beat * 2 + 22, [facts.dmgBeforeMb, facts.dmgNowMb]);
  const stats = [
    {value: '~0%', label: 'CPU at idle', note: 'Native Swift'},
    {value: `${memory} MB`, label: 'memory at idle', note: 'Measured on M4 Pro'},
    {value: `${download.toFixed(1)} MB`, label: 'download', note: `Was ${facts.dmgBeforeMb} MB. 80% smaller.`},
  ];
  return (
    <Backdrop>
      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', gap: square ? 44 : 64}}>
        <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14}}>
          <Eyebrow delay={0}>Built for Apple silicon</Eyebrow>
          <Kinetic
            words={['Everything', 'inside.', {text: 'Barely there.', gold: true}]}
            delay={2}
            size={square ? 84 : 96}
            maxWidth={square ? 960 : undefined}
          />
        </div>
        <div style={{display: 'flex', flexDirection: square ? 'column' : 'row', gap: square ? 20 : 36}}>
          {stats.map((s, i) => {
            const p = pop(frame, fps, 6 + i * beat * 0.75, true);
            return (
              <div
                key={s.label}
                style={{
                  width: square ? 900 : 480,
                  padding: square ? '22px 40px' : '40px 0',
                  borderRadius: 28,
                  background: `${ink.glass}`,
                  border: '1px solid rgba(233,182,90,0.28)',
                  display: 'flex',
                  flexDirection: square ? 'row' : 'column',
                  alignItems: 'center',
                  justifyContent: square ? 'space-between' : 'center',
                  gap: 6,
                  transform: `translateY(${(1 - p) * 70}px)`,
                  opacity: p,
                  fontFamily: display,
                }}
              >
                <div
                  style={{
                    fontSize: square ? 96 : 116,
                    fontWeight: 800,
                    letterSpacing: '-0.05em',
                    fontVariantNumeric: 'tabular-nums',
                    backgroundImage: goldGradient,
                    WebkitBackgroundClip: 'text',
                    WebkitTextFillColor: 'transparent',
                  }}
                >
                  {s.value}
                </div>
                <div style={{display: 'flex', flexDirection: 'column', alignItems: square ? 'flex-end' : 'center', gap: 4}}>
                  <div style={{fontSize: 32, fontWeight: 600, color: ink.text}}>{s.label}</div>
                  <div style={{fontSize: 22, color: ink.textFaint}}>{s.note}</div>
                </div>
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Backdrop>
  );
};
