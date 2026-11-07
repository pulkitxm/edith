import React from 'react';
import {AbsoluteFill, OffthreadVideo, Sequence, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from '../components/Backdrop';
import {Camera, cameraRect, Shot} from '../components/Camera';
import {Eyebrow, Kinetic} from '../components/Kinetic';
import {display, ink, pop, ramp, useLayout} from '../theme';

const source = {width: 2400, height: 1506};
const clip = staticFile('launch/agents-recording.mp4');
const clients = ['Claude Code', 'Codex', 'Cursor', 'Any MCP client'];

const shots = (square: boolean): Shot[] => [
  {at: 0, rect: {x: 0, y: 0, w: 2400, h: 1506}},
  {at: 24, rect: square ? {x: 420, y: 200, w: 1200, h: 330} : {x: 420, y: 200, w: 1700, h: 440}},
  {at: 98, rect: square ? {x: 430, y: 380, w: 1000, h: 690} : {x: 430, y: 372, w: 1450, h: 600}},
  {at: 200, rect: square ? {x: 430, y: 560, w: 1000, h: 690} : {x: 430, y: 520, w: 1450, h: 640}},
];

const segments = [
  {from: 0, length: 51, trimBefore: 15, rate: 1},
  {from: 51, length: 50, trimBefore: 66, rate: 16},
  {from: 101, length: 180, trimBefore: 867, rate: 1},
];

export const agentsDuration = 281;

export const AgentsMcp: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {width, square, u} = useLayout();
  const stage = square
    ? {width: width - 60, height: 700, top: 300}
    : {width: 1720, height: 800, top: 236};
  const enter = pop(frame, fps, 0);
  const rect = cameraRect(frame, shots(square));
  const fastForward = frame >= 51 && frame < 101;
  return (
    <Backdrop glow={ink.coral}>
      <AbsoluteFill style={{alignItems: 'center'}}>
        <div style={{position: 'absolute', top: square ? 70 : 48, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14}}>
          <Eyebrow delay={0}>MCP built in</Eyebrow>
          <Kinetic
            words={['Your', 'agents', 'can', {text: 'use Edith.', gold: true}]}
            delay={2}
            size={square ? 84 : 92}
            maxWidth={square ? 980 : undefined}
          />
        </div>
        <div
          style={{
            position: 'absolute',
            top: stage.top,
            transform: `translateY(${(1 - enter) * 300}px)`,
            boxShadow: `0 50px 140px ${ink.shadow}`,
            borderRadius: 18,
            border: `1px solid ${ink.glassLine}`,
          }}
        >
          <Camera view={stage} source={source} rect={rect}>
            {segments.map((s) => (
              <Sequence key={s.from} from={s.from} durationInFrames={s.length} layout="none">
                <OffthreadVideo
                  src={clip}
                  trimBefore={s.trimBefore}
                  playbackRate={s.rate}
                  muted
                  style={{width: source.width, height: source.height, display: 'block'}}
                />
              </Sequence>
            ))}
          </Camera>
        </div>
        <div
          style={{
            position: 'absolute',
            top: stage.top + 24,
            right: (width - stage.width) / 2 + 24,
            padding: '10px 20px',
            borderRadius: 999,
            background: `${ink.chip}`,
            border: '1px solid rgba(233,182,90,0.5)',
            color: ink.goldLight,
            fontFamily: display,
            fontSize: 24 * Math.max(u, 0.9),
            fontWeight: 600,
            opacity: fastForward ? 1 : 0,
          }}
        >
          Edith tools running · 16x
        </div>
        <div
          style={{
            position: 'absolute',
            bottom: square ? 40 : 34,
            display: 'flex',
            flexWrap: 'wrap',
            justifyContent: 'center',
            gap: 12,
            maxWidth: width - 80,
          }}
        >
          {clients.map((c, i) => {
            const p = pop(frame, fps, 214 + i * 4, true);
            return (
              <div
                key={c}
                style={{
                  transform: `scale(${p})`,
                  opacity: p * ramp(frame, 0, 1),
                  padding: '12px 24px',
                  borderRadius: 999,
                  background: `${ink.chip}`,
                  border: '1px solid rgba(233,182,90,0.5)',
                  color: ink.goldLight,
                  fontFamily: display,
                  fontSize: 26,
                  fontWeight: 600,
                  boxShadow: `0 20px 40px ${ink.shadow}`,
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
