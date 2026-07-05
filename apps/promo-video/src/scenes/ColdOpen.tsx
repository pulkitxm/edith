import React from 'react';
import {useCurrentFrame, useVideoConfig, Img, staticFile, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {colors, fontFamily} from '../tokens';
import {springIn} from '../animation';

export const ColdOpen: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const mark = springIn(frame, fps, 0);
  const word = springIn(frame, fps, 12);

  return (
    <Background>
      <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center'}}>
        <Img
          src={staticFile('logo.png')}
          style={{
            width: 96,
            height: 96,
            borderRadius: 24,
            opacity: interpolate(mark, [0, 1], [0, 1]),
            transform: `scale(${interpolate(mark, [0, 1], [0.7, 1])})`,
          }}
        />
        <div
          style={{
            marginTop: 26,
            fontFamily,
            color: colors.text,
            fontSize: 40,
            fontWeight: 700,
            letterSpacing: 10,
            opacity: interpolate(word, [0, 1], [0, 1]),
            transform: `translateY(${interpolate(word, [0, 1], [14, 0])}px)`,
          }}
        >
          EDITH
        </div>
      </div>
    </Background>
  );
};
