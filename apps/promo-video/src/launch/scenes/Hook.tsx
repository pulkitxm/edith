import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {Kinetic} from '../components/Kinetic';
import {beat, display, ink, pop, ramp, sharp} from '../theme';

const apps = [
  'Clipboard manager',
  'PDF toolkit',
  'Video downloader',
  'Time tracker',
  'Screen recorder',
  'Token tracker',
  'Disk cleaner',
  'Color picker',
  'Music player',
  'App launcher',
  'Video editor',
  'Webcam app',
  'SSH client',
  'Database client',
  'Menu bar stats',
  'Notch app',
];

const slots = apps.map((name, i) => {
  const col = i % 4;
  const row = Math.floor(i / 4);
  const jitter = ((i * 37) % 11) - 5;
  return {name, x: 250 + col * 470 + jitter * 6, y: 330 + row * 150 + jitter * 3, tilt: jitter * 0.8};
});

export const Hook: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const collapse = ramp(frame, 150, 178, [0, 1], sharp);
  const count = Math.min(apps.length, Math.max(0, Math.floor((frame - 6) / 7) + 1));
  return (
    <Backdrop intensity={0.6}>
      <AbsoluteFill>
        {slots.map((s, i) => {
          const p = pop(frame, fps, 6 + i * 7, true);
          const x = interpolate(collapse, [0, 1], [s.x, 960]);
          const y = interpolate(collapse, [0, 1], [s.y, -40]);
          const scale = p * interpolate(collapse, [0, 1], [1, 0.1]);
          return (
            <div
              key={s.name}
              style={{
                position: 'absolute',
                left: x,
                top: y,
                transform: `translate(-50%, -50%) rotate(${s.tilt * (1 - collapse)}deg) scale(${scale})`,
                opacity: p * (1 - collapse * 0.6),
                padding: '20px 30px',
                borderRadius: 18,
                background: 'rgba(255,255,255,0.06)',
                border: '1px solid rgba(255,255,255,0.12)',
                boxShadow: '0 20px 50px rgba(0,0,0,0.4)',
                fontFamily: display,
                fontSize: 34,
                fontWeight: 600,
                color: ink.textSoft,
                whiteSpace: 'nowrap',
                display: 'flex',
                alignItems: 'center',
                gap: 16,
              }}
            >
              <div style={{width: 14, height: 14, borderRadius: 7, background: i % 3 === 0 ? ink.coral : i % 3 === 1 ? ink.blue : ink.violet}} />
              {s.name}
            </div>
          );
        })}
      </AbsoluteFill>
      <AbsoluteFill style={{alignItems: 'center', top: 110, opacity: 1 - collapse}}>
        <div style={{fontFamily: display, fontSize: 64, fontWeight: 700, letterSpacing: '-0.03em', color: ink.text}}>
          <span style={{fontVariantNumeric: 'tabular-nums', color: ink.coral}}>{count}</span> apps to make one Mac work.
        </div>
      </AbsoluteFill>
      {frame >= 170 ? (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
          <Kinetic words={['Or', {text: 'one.', gold: true}]} delay={172} size={220} stagger={beat / 3} />
        </AbsoluteFill>
      ) : null}
    </Backdrop>
  );
};
