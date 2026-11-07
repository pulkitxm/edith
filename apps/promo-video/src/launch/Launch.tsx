import React from 'react';
import {AbsoluteFill, Audio, interpolate, Sequence, staticFile} from 'remotion';
import {type Appearance, applyAppearance, beat, ink} from './theme';
import {Intro, introDuration} from './scenes/Intro';
import {Hook, hookDuration} from './scenes/Hook';
import {Marketplace, storeLength, wallLength} from './scenes/Marketplace';
import {AttentionScreen, DownloadsScreen, StudioScreen, UsageScreen} from './scenes/Screens';
import {AgentsMcp, agentsDuration} from './scenes/AgentsMcp';
import {Shelf} from './scenes/Shelf';
import {Performance} from './scenes/Performance';
import {Privacy} from './scenes/Privacy';
import {Outro} from './scenes/Outro';

const scenes: {id: string; length: number; component: React.FC<{duration: number}>}[] = [
  {id: 'intro', length: introDuration, component: Intro},
  {id: 'hook', length: hookDuration, component: Hook},
  {id: 'marketplace', length: storeLength + wallLength, component: Marketplace},
  {id: 'agents', length: agentsDuration, component: AgentsMcp},
  {id: 'usage', length: beat * 11, component: UsageScreen},
  {id: 'studio', length: beat * 13, component: StudioScreen},
  {id: 'downloads', length: beat * 10, component: DownloadsScreen},
  {id: 'attention', length: beat * 10, component: AttentionScreen},
  {id: 'shelf', length: beat * 9, component: Shelf},
  {id: 'performance', length: beat * 10, component: Performance},
  {id: 'privacy', length: beat * 8, component: Privacy},
  {id: 'outro', length: beat * 10, component: Outro},
];

export const launchDuration = scenes.reduce((sum, s) => sum + s.length, 0);

export const Launch: React.FC<{appearance?: Appearance}> = ({appearance = 'dark'}) => {
  applyAppearance(appearance);
  let start = 0;
  return (
    <AbsoluteFill style={{background: ink.night}}>
      <Audio
        src={staticFile('launch/music.m4a')}
        volume={(f) =>
          interpolate(f, [0, 6, launchDuration - 40, launchDuration], [0, 1, 1, 0], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
          })
        }
      />
      {scenes.map((s) => {
        const from = start;
        start += s.length;
        const Scene = s.component;
        return (
          <Sequence key={s.id} name={s.id} from={from} durationInFrames={s.length}>
            <Scene duration={s.length} />
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};
