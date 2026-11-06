import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {AppWindow} from '../components/AppWindow';
import {Backdrop} from '../components/Backdrop';
import {IconTile} from '../components/Icon';
import {Eyebrow, Kinetic} from '../components/Kinetic';
import {extensions, facts} from '../data';
import {beat, display, goldGradient, ink, pop, ramp, sharp, text} from '../theme';

const categories = ['All', 'Agents', 'Desk', 'Developer', 'Media', 'Utilities', 'Labs'];
const listed = extensions.slice(0, 9);

const Switch: React.FC<{on: number}> = ({on}) => (
  <div
    style={{
      width: 40,
      height: 24,
      borderRadius: 12,
      background: on > 0.5 ? ink.coral : 'rgba(255,255,255,0.14)',
      position: 'relative',
    }}
  >
    <div
      style={{
        position: 'absolute',
        top: 3,
        left: 3 + on * 16,
        width: 18,
        height: 18,
        borderRadius: 9,
        background: '#fff',
      }}
    />
  </div>
);

const InstallRow: React.FC<{index: number; frame: number}> = ({index, frame}) => {
  const e = listed[index];
  const start = 40 + index * (beat / 2);
  const progress = ramp(frame, start, start + 16, [0, 1]);
  const done = frame >= start + 16;
  const installing = frame >= start && !done;
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 16,
        padding: '12px 20px',
        borderBottom: '1px solid rgba(255,255,255,0.06)',
      }}
    >
      <IconTile name={e.id} size={42} tint={done ? ink.text : ink.textSoft} />
      <div style={{flex: 1}}>
        <div style={{fontSize: 18, fontWeight: 600}}>{e.title}</div>
        <div style={{fontSize: 14, color: ink.textSoft, marginTop: 2}}>{e.tagline}</div>
      </div>
      <div style={{width: 170, display: 'flex', justifyContent: 'flex-end'}}>
        {installing ? (
          <div style={{width: 160}}>
            <div style={{height: 6, borderRadius: 3, background: 'rgba(255,255,255,0.1)'}}>
              <div style={{width: `${progress * 100}%`, height: 6, borderRadius: 3, background: ink.coral}} />
            </div>
            <div style={{fontSize: 12, color: ink.textSoft, marginTop: 6}}>Installing {Math.round(progress * 100)}%</div>
          </div>
        ) : done ? (
          <div style={{fontSize: 14, color: ink.green, fontWeight: 600}}>Installed</div>
        ) : (
          <div
            style={{
              padding: '6px 18px',
              borderRadius: 8,
              background: ink.coral,
              color: '#1a0f0b',
              fontWeight: 700,
              fontSize: 14,
            }}
          >
            Get
          </div>
        )}
      </div>
      <Switch on={ramp(frame, start + 16, start + 22)} />
    </div>
  );
};

const Store: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = pop(frame, fps, 0);
  const leave = ramp(frame, 132, 150, [0, 1], sharp);
  return (
    <AbsoluteFill style={{alignItems: 'center'}}>
      <div style={{position: 'absolute', top: 70, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 18, opacity: 1 - leave}}>
        <Eyebrow delay={2}>New · Extension marketplace</Eyebrow>
        <Kinetic words={['Pick', 'what', 'you', {text: 'need.', gold: true}]} delay={6} size={84} stagger={3} />
      </div>
      <div
        style={{
          position: 'absolute',
          top: 300,
          transform: `translateY(${interpolate(enter, [0, 1], [500, 0]) + leave * 80}px) perspective(2400px) rotateX(${(1 - enter) * 18}deg) scale(0.84)`,
          transformOrigin: 'top center',
          opacity: 1 - leave,
        }}
      >
        <AppWindow active="Extensions" title="Extensions" height={980}>
          <div style={{display: 'flex', gap: 10, padding: '0 36px 18px'}}>
            {categories.map((c, i) => (
              <div
                key={c}
                style={{
                  padding: '7px 16px',
                  borderRadius: 999,
                  fontSize: 14,
                  fontWeight: 600,
                  background: i === 0 ? 'rgba(224,138,106,0.2)' : 'rgba(255,255,255,0.06)',
                  color: i === 0 ? ink.coral : ink.textSoft,
                }}
              >
                {c}
              </div>
            ))}
          </div>
          <div style={{margin: '0 36px', borderRadius: 14, background: '#1d1d20', border: '1px solid rgba(255,255,255,0.06)', fontFamily: text}}>
            {listed.map((e, i) => (
              <InstallRow key={e.id} index={i} frame={frame} />
            ))}
          </div>
        </AppWindow>
      </div>
    </AbsoluteFill>
  );
};

const Wall: React.FC<{frame: number}> = ({frame}) => {
  const {fps} = useVideoConfig();
  const cols = 9;
  const size = 104;
  const gap = 34;
  const count = Math.round(interpolate(frame, [0, 60], [0, facts.extensions], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}));
  const zoom = interpolate(frame, [0, 138], [1.08, 1]);
  return (
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: `repeat(${cols}, ${size}px)`,
          gap,
          transform: `scale(${zoom})`,
          opacity: 0.55,
        }}
      >
        {extensions.map((e, i) => {
          const col = i % cols;
          const row = Math.floor(i / cols);
          const d = Math.hypot(col - 4, row - 2);
          const p = pop(frame, fps, d * 4, true);
          return (
            <div key={e.id} style={{transform: `scale(${p})`, opacity: p}}>
              <IconTile name={e.id} size={size} glow={0.3} />
            </div>
          );
        })}
      </div>
      <AbsoluteFill
        style={{
          alignItems: 'center',
          justifyContent: 'center',
          background: 'radial-gradient(40% 36% at 50% 50%, rgba(5,8,15,0.92), rgba(5,8,15,0.2) 100%)',
        }}
      >
        <div
          style={{
            fontFamily: display,
            fontSize: 300,
            fontWeight: 800,
            letterSpacing: '-0.06em',
            lineHeight: 0.9,
            backgroundImage: goldGradient,
            WebkitBackgroundClip: 'text',
            WebkitTextFillColor: 'transparent',
            fontVariantNumeric: 'tabular-nums',
          }}
        >
          {count}
        </div>
        <div style={{fontFamily: display, fontSize: 56, fontWeight: 700, color: ink.text, letterSpacing: '-0.03em'}}>
          extensions. One click each.
        </div>
        <div style={{fontFamily: display, fontSize: 28, color: ink.textSoft, marginTop: 18, opacity: ramp(frame, 40, 60)}}>
          Install, update or remove any of them whenever you like. More on the way.
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

export const Marketplace: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <Backdrop glow={ink.coral}>
      {frame < 150 ? <Store /> : <Wall frame={frame - 150} />}
    </Backdrop>
  );
};
