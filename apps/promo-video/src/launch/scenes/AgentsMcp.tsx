import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {AppWindow} from '../components/AppWindow';
import {Backdrop} from '../components/Backdrop';
import {Icon} from '../components/Icon';
import {Eyebrow, Kinetic} from '../components/Kinetic';
import {display, ink, mono, pop, ramp} from '../theme';

const prompt = 'what is my screen time today?';
const tabs = ['Board', 'Landing page copy', 'Fix flaky test', 'Screen time today'];
const calls = ['edith_attention_summary', 'edith_attention_breakdown'];
const table: [string, string, string][] = [
  ['Productive', '4h 26m', '62%'],
  ['Neutral', '1h 48m', '25%'],
  ['Distracting', '0h 58m', '13%'],
];
const apps = ['Xcode: 2h 04m', 'Figma: 1h 12m', 'Terminal: 58m', 'Safari: 41m', 'Notes: 33m'];
const clients = ['Claude Code', 'Codex', 'Cursor', 'Any MCP client'];

const reveal = (frame: number, at: number) => ({
  opacity: ramp(frame, at, at + 6),
  transform: `translateY(${ramp(frame, at, at + 8, [8, 0])}px)`,
});

const Terminal: React.FC<{frame: number}> = ({frame}) => {
  const typed = prompt.slice(0, Math.max(0, Math.floor((frame - 24) / 1.2)));
  const answerAt = 96;
  const cursorOn = Math.floor(frame / 8) % 2 === 0;
  return (
    <div style={{fontFamily: mono, fontSize: 21, lineHeight: 1.5, color: '#d8d8dc', padding: '6px 36px'}}>
      <div style={{display: 'flex', gap: 18, alignItems: 'center', marginBottom: 14}}>
        <div style={{width: 54, height: 40, borderRadius: 8, background: ink.coral, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#1a0f0b', fontWeight: 800}}>
          {'>_'}
        </div>
        <div>
          <div style={{color: ink.text, fontWeight: 700}}>Claude Code</div>
          <div style={{color: ink.textFaint}}>~/projects/site</div>
        </div>
      </div>
      <div style={{background: 'rgba(255,255,255,0.06)', padding: '2px 8px', margin: '0 -8px'}}>
        <span style={{color: ink.textFaint}}>{'> '}</span>
        {typed}
        {frame < 70 && cursorOn ? <span style={{background: ink.text, color: ink.text}}>.</span> : null}
      </div>
      {calls.map((c, i) => (
        <div key={c} style={{...reveal(frame, 66 + i * 9), color: ink.textFaint, marginTop: i === 0 ? 12 : 0}}>
          <span style={{color: frame > 90 ? ink.green : ink.gold}}>{frame > 90 ? '✓' : '◐'}</span> edith · {c}
        </div>
      ))}
      <div style={{...reveal(frame, answerAt), marginTop: 12}}>
        <span style={{color: ink.text}}>●</span> Your screen time today is <b style={{color: ink.text}}>7h 12m of active time</b>, from 9:00 AM to 6:10 PM.
      </div>
      <div style={{...reveal(frame, answerAt + 10), display: 'inline-grid', gridTemplateColumns: '200px 130px 100px', border: '1px solid #55555a', margin: '14px 0'}}>
        {[['', 'Time', 'Share'], ...table].map((row, r) =>
          row.map((cell, c) => (
            <div key={`${r}-${c}`} style={{padding: '5px 12px', borderRight: c < 2 ? '1px solid #55555a' : undefined, borderBottom: r < 3 ? '1px solid #55555a' : undefined}}>
              {cell}
            </div>
          )),
        )}
      </div>
      <div style={{...reveal(frame, answerAt + 22), fontWeight: 700, color: ink.text}}>Top apps and sites:</div>
      {apps.map((a, i) => (
        <div key={a} style={reveal(frame, answerAt + 26 + i * 4)}>
          {i + 1}. {a}
        </div>
      ))}
      <div style={{...reveal(frame, answerAt + 50), marginTop: 12, color: ink.textSoft}}>
        These numbers come from Edith's Attention tracker on this Mac.
      </div>
    </div>
  );
};

export const AgentsMcp: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const enter = pop(frame, fps, 0);
  const drift = interpolate(frame, [0, 216], [0, -30]);
  return (
    <Backdrop glow={ink.coral}>
      <AbsoluteFill style={{alignItems: 'center'}}>
        <div style={{position: 'absolute', top: 60, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16}}>
          <Eyebrow delay={2}>MCP built in</Eyebrow>
          <Kinetic words={['Your', 'agents', 'can', {text: 'use Edith.', gold: true}]} delay={6} size={76} />
        </div>
        <div
          style={{
            position: 'absolute',
            top: 250,
            transform: `translateY(${interpolate(enter, [0, 1], [400, drift])}px) scale(0.86)`,
            transformOrigin: 'top center',
          }}
        >
          <AppWindow
            active="Agents"
            title="Agents"
            height={980}
            actions={
              <div style={{display: 'flex', gap: 22}}>
                {['search', 'plus', 'refresh', 'info'].map((n) => (
                  <Icon key={n} name={n} size={20} color={ink.textSoft} />
                ))}
              </div>
            }
          >
            <div style={{display: 'flex', gap: 8, padding: '0 36px 16px', borderBottom: '1px solid rgba(255,255,255,0.06)', marginBottom: 16}}>
              {tabs.map((t, i) => {
                const last = i === tabs.length - 1;
                return (
                  <div
                    key={t}
                    style={{
                      padding: '7px 14px',
                      borderRadius: 8,
                      fontSize: 14,
                      fontWeight: 600,
                      background: last ? 'rgba(255,255,255,0.12)' : 'rgba(255,255,255,0.05)',
                      color: last ? ink.text : ink.textSoft,
                      opacity: last ? ramp(frame, 12, 20) : 1,
                    }}
                  >
                    {i > 0 ? '✳ ' : ''}
                    {t}
                  </div>
                );
              })}
            </div>
            <Terminal frame={frame} />
          </AppWindow>
        </div>
        <div style={{position: 'absolute', bottom: 54, display: 'flex', gap: 14}}>
          {clients.map((c, i) => {
            const p = pop(frame, fps, 150 + i * 4, true);
            return (
              <div
                key={c}
                style={{
                  transform: `scale(${p})`,
                  opacity: p,
                  padding: '14px 26px',
                  borderRadius: 999,
                  background: 'rgba(10,23,48,0.92)',
                  border: '1px solid rgba(233,182,90,0.45)',
                  color: ink.goldLight,
                  fontFamily: display,
                  fontSize: 26,
                  fontWeight: 600,
                  boxShadow: '0 20px 40px rgba(0,0,0,0.5)',
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
