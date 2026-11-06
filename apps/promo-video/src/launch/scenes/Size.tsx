import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {Eyebrow, Kinetic} from '../components/Kinetic';
import {facts} from '../data';
import {display, goldGradient, ink, ramp, smooth} from '../theme';

export const Size: React.FC = () => {
  const frame = useCurrentFrame();
  const shrink = ramp(frame, 18, 66, [0, 1], smooth);
  const mb = interpolate(shrink, [0, 1], [facts.dmgBeforeMb, facts.dmgNowMb]);
  const saved = Math.round((1 - facts.dmgNowMb / facts.dmgBeforeMb) * 100);
  const barMax = 1300;
  return (
    <Backdrop>
      <AbsoluteFill style={{padding: '0 230px', gap: 34, justifyContent: 'center'}}>
        <Eyebrow delay={2}>The download</Eyebrow>
        <div
          style={{
            fontFamily: display,
            fontSize: 260,
            fontWeight: 800,
            letterSpacing: '-0.06em',
            lineHeight: 0.9,
            fontVariantNumeric: 'tabular-nums',
            backgroundImage: goldGradient,
            WebkitBackgroundClip: 'text',
            WebkitTextFillColor: 'transparent',
          }}
        >
          {mb.toFixed(1)} MB
        </div>
        <div style={{display: 'flex', flexDirection: 'column', gap: 18, marginTop: 20}}>
          <div style={{display: 'flex', alignItems: 'center', gap: 24}}>
            <div style={{width: barMax, height: 26, borderRadius: 13, background: 'rgba(255,255,255,0.08)'}}>
              <div
                style={{
                  width: (mb / facts.dmgBeforeMb) * barMax,
                  height: 26,
                  borderRadius: 13,
                  background: goldGradient,
                  boxShadow: '0 0 40px rgba(233,182,90,0.4)',
                }}
              />
            </div>
          </div>
          <div style={{display: 'flex', justifyContent: 'space-between', width: barMax, fontFamily: display, fontSize: 26, color: ink.textFaint}}>
            <span>Edith today</span>
            <span>Before the marketplace: {facts.dmgBeforeMb} MB</span>
          </div>
        </div>
        {frame >= 70 ? (
          <div style={{marginTop: 30}}>
            <Kinetic
              words={[{text: `${saved}% lighter.`, gold: true}, 'Install', 'only', 'what', 'you', 'use.']}
              delay={72}
              size={72}
              align="left"
              stagger={3}
            />
          </div>
        ) : null}
      </AbsoluteFill>
    </Backdrop>
  );
};
