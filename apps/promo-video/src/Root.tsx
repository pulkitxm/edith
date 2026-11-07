import {Composition} from 'remotion';
import {Main} from './Main';
import {OneApp, oneAppTotalDuration} from './OneApp';
import {Announcement, announcementDuration} from './Announcement';
import {totalDuration, fps} from './tokens';
import {Launch, launchDuration} from './launch/Launch';

export const Root: React.FC = () => {
  return (
    <>
      <Composition
        id="Main"
        component={Main}
        durationInFrames={totalDuration}
        fps={fps}
        width={1920}
        height={1080}
      />
      <Composition
        id="Announcement"
        component={Announcement}
        durationInFrames={announcementDuration}
        fps={fps}
        width={1920}
        height={1080}
      />
      <Composition
        id="V1-launch-youtube"
        component={Launch}
        durationInFrames={launchDuration}
        fps={fps}
        width={1920}
        height={1080}
      />
      <Composition
        id="launch-web-light"
        component={Launch}
        durationInFrames={launchDuration}
        fps={fps}
        width={1920}
        height={1080}
        defaultProps={{appearance: 'light' as const}}
      />
      <Composition
        id="V1-launch-x"
        component={Launch}
        durationInFrames={launchDuration}
        fps={fps}
        width={1080}
        height={1080}
      />
      <Composition
        id="OneApp"
        component={OneApp}
        durationInFrames={oneAppTotalDuration}
        fps={fps}
        width={1920}
        height={1080}
      />
    </>
  );
};
