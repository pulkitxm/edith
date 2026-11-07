import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {Kinetic} from '../components/Kinetic';
import {NotchMark} from '../components/NotchMark';
import {beat, display, ink, pop, ramp, sharp, useLayout} from '../theme';

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

export const hookDuration = beat * 10;

export const Hook: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {width, height, square} = useLayout();
  const cols = square ? 3 : 4;
  const colGap = square ? 340 : 440;
  const rowGap = square ? 110 : 140;
  const rows = Math.ceil(apps.length / cols);
  const top = height / 2 - ((rows - 1) * rowGap) / 2 + (square ? 50 : 40);
  const collapse = ramp(frame, beat * 5, beat * 5 + 14, [0, 1], sharp);
  const count = Math.min(apps.length, Math.max(0, Math.floor(frame / 2) + 1));
  const logo = pop(frame, fps, beat * 5 + 10, true);
  return (
    <Backdrop intensity={0.6}>
      <AbsoluteFill>
        {apps.map((name, i) => {
          const col = i % cols;
          const row = Math.floor(i / cols);
          const jitter = ((i * 37) % 11) - 5;
          const sx = width / 2 + (col - (cols - 1) / 2) * colGap + jitter * 4;
          const sy = top + row * rowGap + jitter * 2;
          const p = pop(frame, fps, i * 2, true);
          const x = interpolate(collapse, [0, 1], [sx, width / 2]);
          const y = interpolate(collapse, [0, 1], [sy, height / 2]);
          return (
            <div
              key={name}
              style={{
                position: 'absolute',
                left: x,
                top: y,
                transform: `translate(-50%, -50%) rotate(${jitter * 0.8 * (1 - collapse)}deg) scale(${p * (1 - collapse * 0.9)})`,
                opacity: p * (1 - collapse),
                padding: square ? '16px 24px' : '18px 28px',
                borderRadius: 16,
                background: `${ink.glass}`,
                border: `1px solid ${ink.glassLine}`,
                fontFamily: display,
                fontSize: square ? 28 : 32,
                fontWeight: 600,
                color: ink.textSoft,
                whiteSpace: 'nowrap',
                display: 'flex',
                alignItems: 'center',
                gap: 14,
              }}
            >
              <div style={{width: 12, height: 12, borderRadius: 6, background: [ink.coral, ink.blue, ink.violet][i % 3]}} />
              {name}
            </div>
          );
        })}
      </AbsoluteFill>
      <AbsoluteFill style={{alignItems: 'center', top: square ? 110 : 90, opacity: 1 - collapse}}>
        <div style={{fontFamily: display, fontSize: square ? 64 : 72, fontWeight: 800, letterSpacing: '-0.035em', color: ink.text, textAlign: 'center'}}>
          <span style={{fontVariantNumeric: 'tabular-nums', color: ink.coral}}>{count}</span> apps {square ? <br /> : null}to install, update and pay for.
        </div>
      </AbsoluteFill>
      {frame >= beat * 5 + 6 ? (
        <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', gap: 30}}>
          <div style={{transform: `scale(${logo})`, filter: 'drop-shadow(0 20px 50px rgba(233,182,90,0.35))'}}>
            <NotchMark size={170} />
          </div>
          <Kinetic words={['Now', 'it', 'is', {text: 'one.', gold: true}]} delay={beat * 5 + 12} size={square ? 120 : 132} stagger={3} />
        </AbsoluteFill>
      ) : null}
    </Backdrop>
  );
};
