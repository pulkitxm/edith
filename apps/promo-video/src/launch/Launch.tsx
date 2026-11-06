import React from 'react';
import {AbsoluteFill, Audio, interpolate, Sequence, staticFile} from 'remotion';
import {bar} from './theme';
import {Hook} from './scenes/Hook';
import {Reveal} from './scenes/Reveal';
import {Size} from './scenes/Size';

const scenes: {id: string; bars: number; component: React.FC}[] = [
  {id: 'hook', bars: 3, component: Hook},
  {id: 'reveal', bars: 3, component: Reveal},
  {id: 'size', bars: 2, component: Size},
];

const tail = 63;

export const launchDuration = scenes.reduce((sum, s) => sum + s.bars * bar, 0) + tail;

export const Launch: React.FC = () => {
  let start = 0;
  return (
    <AbsoluteFill style={{background: '#05080f'}}>
      <Audio
        src={staticFile('announce/music-bed.m4a')}
        volume={(f) =>
          interpolate(f, [0, 12, launchDuration - 45, launchDuration], [0, 0.9, 0.9, 0], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
          })
        }
      />
      {scenes.map((s, i) => {
        const from = start;
        const length = s.bars * bar + (i === scenes.length - 1 ? tail : 0);
        start += s.bars * bar;
        const Scene = s.component;
        return (
          <Sequence key={s.id} name={s.id} from={from} durationInFrames={length}>
            <Scene />
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};
