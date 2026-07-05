import React from 'react';
import {TransitionSeries, linearTiming} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {durations, transitionFrames} from './tokens';
import {ColdOpen} from './scenes/ColdOpen';
import {AgentUsageRings} from './scenes/AgentUsageRings';
import {ActivityHeatmap} from './scenes/ActivityHeatmap';
import {UsageStats} from './scenes/UsageStats';
import {SystemScene} from './scenes/SystemScene';
import {MusicScene} from './scenes/MusicScene';
import {CalendarScene} from './scenes/CalendarScene';
import {MenuBarBadgeScene} from './scenes/MenuBarBadgeScene';
import {NotificationScene} from './scenes/NotificationScene';
import {ShortcutScene} from './scenes/ShortcutScene';
import {SettingsMontage} from './scenes/SettingsMontage';
import {TrustScene} from './scenes/TrustScene';
import {Outro} from './scenes/Outro';

// A short crossfade between every beat so cuts read as intentional instead
// of abrupt - each transition overlaps (and slightly shortens) its neighbors.
const T = () => (
  <TransitionSeries.Transition
    presentation={fade()}
    timing={linearTiming({durationInFrames: transitionFrames})}
  />
);

export const Main: React.FC = () => {
  return (
    <TransitionSeries>
      <TransitionSeries.Sequence durationInFrames={durations.coldOpen}>
        <ColdOpen />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.rings}>
        <AgentUsageRings />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.heatmap}>
        <ActivityHeatmap />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.stats}>
        <UsageStats />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.system}>
        <SystemScene />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.music}>
        <MusicScene />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.calendar}>
        <CalendarScene />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.menuBar}>
        <MenuBarBadgeScene />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.notification}>
        <NotificationScene />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.shortcut}>
        <ShortcutScene />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.settings}>
        <SettingsMontage />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.trust}>
        <TrustScene />
      </TransitionSeries.Sequence>
      {T()}
      <TransitionSeries.Sequence durationInFrames={durations.outro}>
        <Outro />
      </TransitionSeries.Sequence>
    </TransitionSeries>
  );
};
