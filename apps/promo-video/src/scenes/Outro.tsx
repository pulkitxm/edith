import React from 'react';
import {useCurrentFrame, useVideoConfig, Img, staticFile, interpolate, AbsoluteFill} from 'remotion';
import {Background} from '../components/Background';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

export const Outro: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps, durationInFrames} = useVideoConfig();

  const mark = springIn(frame, fps, 0);
  const tagline = springIn(frame, fps, 14);
  const fadeOut = interpolate(
    frame,
    [durationInFrames - 20, durationInFrames - 2],
    [1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
  );

  return (
    <Background>
      <AbsoluteFill style={{opacity: fadeOut, alignItems: 'center', justifyContent: 'center', display: 'flex', flexDirection: 'column'}}>
        <Img
          src={staticFile('logo.png')}
          style={{
            width: 84,
            height: 84,
            borderRadius: 20,
            opacity: interpolate(mark, [0, 1], [0, 1]),
            transform: `scale(${interpolate(mark, [0, 1], [0.8, 1])})`,
          }}
        />
        <div
          style={{
            marginTop: 22,
            fontFamily,
            color: colors.text,
            fontSize: 30,
            fontWeight: 700,
            letterSpacing: 6,
          }}
        >
          EDITH
        </div>
        <div
          style={{
            marginTop: 14,
            fontFamily,
            color: colors.textDim,
            fontSize: 18,
            letterSpacing: 1,
            opacity: interpolate(tagline, [0, 1], [0, 1]),
            transform: `translateY(${interpolate(tagline, [0, 1], [10, 0])}px)`,
          }}
        >
          Built to run 24/7.
        </div>
      </AbsoluteFill>
    </Background>
  );
};
