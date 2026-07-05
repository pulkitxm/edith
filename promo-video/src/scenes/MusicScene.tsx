import React from 'react';
import {useCurrentFrame, useVideoConfig, interpolate} from 'remotion';
import {Background} from '../components/Background';
import {AppFrame} from '../components/AppFrame';
import {MiniPlayer} from '../components/MiniPlayer';
import {TrackRow} from '../components/TrackRow';
import {Caption} from '../components/Caption';
import {springIn} from '../animation';

const TRACKS = [
  {title: 'The Night We Met', duration: '3:28', hue: 20, current: true},
  {title: 'Dandelions', duration: '3:02', hue: 45},
  {title: 'Paris', duration: '3:44', hue: 200},
];

export const MusicScene: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps, durationInFrames} = useVideoConfig();

  const tabIndex = interpolate(springIn(frame, fps, 0), [0, 1], [2, 1]);
  const scrub = interpolate(frame, [35, durationInFrames - 15], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  const bars = Array.from({length: 5}).map((_, i) =>
    Math.abs(Math.sin(frame / 5 + i * 1.3)),
  );

  return (
    <Background>
      <AppFrame activeIndex={tabIndex}>
        {TRACKS.map((t, i) => {
          const p = interpolate(springIn(frame, fps, 24 + i * 6), [0, 1], [0, 1]);
          return (
            <TrackRow
              key={t.title}
              title={t.title}
              duration={t.duration}
              hue={t.hue}
              current={t.current}
              playing
              opacity={p}
            />
          );
        })}
        <div style={{marginTop: 18, paddingTop: 18, borderTop: '1px solid rgba(255,255,255,0.06)'}}>
          <MiniPlayer title="The Night We Met" progress={scrub} duration={208} playing bars={bars} />
        </div>
      </AppFrame>
      <Caption>Play whatever's in your music folder</Caption>
    </Background>
  );
};
