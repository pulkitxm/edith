import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {Backdrop} from './Backdrop';
import {Camera, cameraRect, Shot} from './Camera';
import {Eyebrow, Kinetic, Word} from './Kinetic';
import {captureDir, ink, pop, ramp, useLayout} from '../theme';

export const capture = {width: 3200, height: 2000};

export type Frame = {src: string; from: number};

const Layers: React.FC<{frames: Frame[]; frame: number}> = ({frames, frame}) => (
  <>
    {frames.map((f, i) => (
      <Img
        key={f.src + f.from}
        src={staticFile(`${captureDir}/${f.src}.png`)}
        style={{
          position: 'absolute',
          inset: 0,
          width: capture.width,
          height: capture.height,
          opacity: i === 0 ? 1 : ramp(frame, f.from, f.from + 6),
        }}
      />
    ))}
  </>
);

export const ScreenStage: React.FC<{
  eyebrow: string;
  title: Word[];
  frames: Frame[];
  shots: {wide: Shot[]; square: Shot[]};
  glow?: string;
  children?: React.ReactNode;
}> = ({eyebrow, title, frames, shots, glow, children}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const {width, height, square} = useLayout();
  const stage = square
    ? {width: width - 60, height: height - 300, top: 270}
    : {width: 1720, height: 830, top: 214};
  const enter = pop(frame, fps, 0);
  const rect = cameraRect(frame, square ? shots.square : shots.wide);
  return (
    <Backdrop glow={glow ?? ink.gold}>
      <AbsoluteFill style={{alignItems: 'center'}}>
        <div style={{position: 'absolute', top: square ? 60 : 36, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12}}>
          <Eyebrow delay={0}>{eyebrow}</Eyebrow>
          <Kinetic words={title} delay={2} size={square ? 78 : 88} maxWidth={square ? 980 : undefined} />
        </div>
        <div
          style={{
            position: 'absolute',
            top: stage.top,
            transform: `translateY(${(1 - enter) * 260}px) scale(${0.96 + enter * 0.04})`,
            boxShadow: `0 50px 140px ${ink.shadow}`,
            borderRadius: 22,
          }}
        >
          <Camera view={stage} source={capture} rect={rect} radius={22}>
            <Layers frames={frames} frame={frame} />
          </Camera>
        </div>
        {children}
      </AbsoluteFill>
    </Backdrop>
  );
};
